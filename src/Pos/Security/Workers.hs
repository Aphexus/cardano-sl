{-# LANGUAGE ScopedTypeVariables #-}

module Pos.Security.Workers
       ( SecurityWorkersClass (..)
       ) where

import           Control.Concurrent.STM     (TVar, newTVar, readTVar, writeTVar)
import qualified Data.HashMap.Strict        as HM
import           Data.Tagged                (Tagged (..))
import           Data.Time.Units            (Millisecond, convertUnit)
import           Formatting                 (build, int, sformat, (%))
import           Mockable                   (delay)
import           Paths_cardano_sl           (version)
import           Serokell.Util              (sec)
import           System.Wlog                (logWarning)
import           Universum

import           Pos.Binary.Ssc             ()
import           Pos.Block.Network          (needRecovery, requestTipOuts,
                                             triggerRecovery)
import           Pos.Communication.Protocol (OutSpecs, SendActions, WorkerSpec,
                                             localWorker, worker, NodeId)
import           Pos.Constants              (blkSecurityParam, mdNoBlocksSlotThreshold,
                                             mdNoCommitmentsEpochThreshold)
import           Pos.Context                (getNodeContext, getUptime, isRecoveryMode,
                                             ncPublicKey)
import           Pos.Crypto                 (PublicKey)
import           Pos.DB                     (DBError (DBMalformed))
import           Pos.DB.Block               (getBlockHeader)
import           Pos.DB.Class               (MonadDB)
import           Pos.DB.DB                  (getTipBlockHeader, loadBlundsFromTipByDepth)
import           Pos.Reporting.Methods      (reportMisbehaviourMasked, reportingFatal)
import           Pos.Security.Class         (SecurityWorkersClass (..))
import           Pos.Shutdown               (runIfNotShutdown)
import           Pos.Slotting               (getCurrentSlot, getLastKnownSlotDuration,
                                             onNewSlot)
import           Pos.Ssc.Class              (SscHelpersClass, SscWorkersClass)
import           Pos.Ssc.GodTossing         (GtPayload (..), SscGodTossing,
                                             getCommitmentsMap)
import           Pos.Ssc.NistBeacon         (SscNistBeacon)
import           Pos.Types                  (Block, BlockHeader, EpochIndex, MainBlock,
                                             SlotId (..), addressHash, blockMpc,
                                             blockSlot, flattenEpochOrSlot, flattenSlotId,
                                             genesisHash, headerHash, headerLeaderKey,
                                             prevBlockL)
import           Pos.Util                   (mconcatPair)
import           Pos.Util.Chrono            (NewestFirst (..))
import           Pos.WorkMode               (WorkMode)


instance SecurityWorkersClass SscGodTossing where
    securityWorkers getPeers =
        Tagged $
        merge [checkForReceivedBlocksWorker getPeers, checkForIgnoredCommitmentsWorker]
      where
        merge = mconcatPair . map (first pure)

instance SecurityWorkersClass SscNistBeacon where
    securityWorkers getPeers = Tagged $ first pure (checkForReceivedBlocksWorker getPeers)

checkForReceivedBlocksWorker ::
    (SscWorkersClass ssc, WorkMode ssc m)
    => m (Set NodeId) -> (WorkerSpec m, OutSpecs)
checkForReceivedBlocksWorker getPeers =
    worker requestTipOuts (checkForReceivedBlocksWorkerImpl getPeers)

checkEclipsed
    :: (SscHelpersClass ssc, MonadDB m)
    => PublicKey -> SlotId -> BlockHeader ssc -> m Bool
checkEclipsed ourPk slotId x = notEclipsed x
  where
    onBlockLoadFailure header = do
        throwM $ DBMalformed $
            sformat ("Eclipse check: didn't manage to find parent of "%build%
                     " with hash "%build%", which is not genesis")
                    (headerHash header)
                    (header ^. prevBlockL)
    -- We stop looking for blocks when we've gone earlier than
    -- 'mdNoBlocksSlotThreshold':
    pastThreshold header =
        (flattenSlotId slotId - flattenEpochOrSlot header) >
        mdNoBlocksSlotThreshold
    -- Run the iteration starting from tip block; if we have found
    -- that we're eclipsed, we report it and ask neighbors for
    -- headers. If there are no main blocks generated by someone else
    -- in the past 'mdNoBlocksSlotThreshold' slots, it's bad and we've
    -- been eclipsed.  Here's how we determine that a block is good
    -- (i.e. main block generated not by us):
    isGoodBlock (Left _)   = False
    isGoodBlock (Right mb) = mb ^. headerLeaderKey /= ourPk
    -- Okay, now let's iterate until we see a good blocks or until we
    -- go past the threshold and there's no point in looking anymore:
    notEclipsed header = do
        let prevBlock = header ^. prevBlockL
        if | pastThreshold header     -> pure False
           | prevBlock == genesisHash -> pure True
           | isGoodBlock header       -> pure True
           | otherwise                ->
                 getBlockHeader prevBlock >>= \case
                     Just h  -> notEclipsed h
                     Nothing -> onBlockLoadFailure header $> True

checkForReceivedBlocksWorkerImpl
    :: forall ssc m.
       (SscWorkersClass ssc, WorkMode ssc m)
    => m (Set NodeId) -> SendActions m -> m ()
checkForReceivedBlocksWorkerImpl getPeers sendActions = afterDelay $ do
    repeatOnInterval (const (sec' 4)) . reportingFatal version $
        whenM (needRecovery $ Proxy @ssc) $
            triggerRecovery getPeers sendActions
    repeatOnInterval (min (sec' 20)) . reportingFatal version $ do
        ourPk <- ncPublicKey <$> getNodeContext
        let onSlotDefault slotId = do
                header <- getTipBlockHeader @ssc
                unlessM (checkEclipsed ourPk slotId header) onEclipsed
        maybe (pure ()) onSlotDefault =<< getCurrentSlot
  where
    sec' :: Int -> Millisecond
    sec' = convertUnit . sec
    afterDelay action = delay (sec 3) >> action
    onEclipsed = do
        logWarning $
            "Our neighbors are likely trying to carry out an eclipse attack! " <>
            "There are no blocks younger " <>
            "than 'mdNoBlocksSlotThreshold' that we didn't generate " <>
            "by ourselves"
        reportEclipse
    repeatOnInterval delF action = runIfNotShutdown $ do
        () <- action
        getLastKnownSlotDuration >>= delay . delF
        repeatOnInterval delF action
    reportEclipse = do
        bootstrapMin <- (+ sec 10) . convertUnit <$> getLastKnownSlotDuration
        nonTrivialUptime <- (> bootstrapMin) <$> getUptime
        isRecovery <- isRecoveryMode
        let reason =
                "Eclipse attack was discovered, mdNoBlocksSlotThreshold: " <>
                show (mdNoBlocksSlotThreshold :: Int)
        when (nonTrivialUptime && not isRecovery) $
            reportMisbehaviourMasked version reason


checkForIgnoredCommitmentsWorker
    :: forall m.
       WorkMode SscGodTossing m
    => (WorkerSpec m, OutSpecs)
checkForIgnoredCommitmentsWorker = localWorker $ do
    epochIdx <- atomically (newTVar 0)
    void $ onNewSlot True (checkForIgnoredCommitmentsWorkerImpl epochIdx)

checkForIgnoredCommitmentsWorkerImpl
    :: forall m. (WorkMode SscGodTossing m)
    => TVar EpochIndex -> SlotId -> m ()
checkForIgnoredCommitmentsWorkerImpl tvar slotId = do
    -- Check prev blocks
    (kBlocks :: NewestFirst [] (Block SscGodTossing)) <-
        map fst <$> loadBlundsFromTipByDepth @SscGodTossing blkSecurityParam
    forM_ kBlocks $ \blk -> whenRight blk checkCommitmentsInBlock

    -- Print warning
    lastCommitment <- atomically $ readTVar tvar
    when (siEpoch slotId - lastCommitment > mdNoCommitmentsEpochThreshold) $
        logWarning $ sformat
            ("Our neighbors are likely trying to carry out an eclipse attack! "%
             "Last commitment was at epoch "%int%", "%
             "which is more than 'mdNoCommitmentsEpochThreshold' epochs ago")
            lastCommitment
  where
    checkCommitmentsInBlock :: MainBlock SscGodTossing -> m ()
    checkCommitmentsInBlock block = do
        ourId <- addressHash . ncPublicKey <$> getNodeContext
        let commitmentInBlockchain = isCommitmentInPayload ourId (block ^. blockMpc)
        when commitmentInBlockchain $
            atomically $ writeTVar tvar $ siEpoch $ block ^. blockSlot
    isCommitmentInPayload addr (CommitmentsPayload commitments _) =
        HM.member addr $ getCommitmentsMap commitments
    isCommitmentInPayload _ _ = False
