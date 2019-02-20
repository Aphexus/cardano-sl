{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE Rank2Types     #-}

-- | VSS certificates and secrets related stuff.

module Pos.Client.CLI.Secrets
       ( prepareUserSecret
       ) where

import           Universum

import           Control.Lens (ix)
import           Crypto.Random (MonadRandom)

import           Pos.Chain.Genesis (GeneratedSecrets (..), RichSecrets (..))
import           Pos.Crypto (SecretKey, VssKeyPair, keyGen, runSecureRandom,
                     vssKeyGen)
import           Pos.Util.UserSecret (UserSecret, usPrimKey, usVss,
                     writeUserSecret)
import           Pos.Util.Trace (Trace, traceWith)

import           Pos.Client.CLI.NodeOptions (CommonNodeArgs (..))

-- | This function prepares 'UserSecret' for later usage by node. It
-- ensures that primary key and VSS key are present in
-- 'UserSecret'. They are either taken from generated secrets or
-- generated by this function using secure source of randomness.
prepareUserSecret
    :: (MonadIO m)
    => Trace m Text
    -> CommonNodeArgs
    -> Maybe GeneratedSecrets
    -> UserSecret
    -> m (SecretKey, UserSecret)
prepareUserSecret logTrace CommonNodeArgs {devGenesisSecretI} mGeneratedSecrets userSecret = do
    (_, userSecretWithVss) <-
        fillUserSecretVSS logTrace (rsVssKeyPair <$> predefinedRichKeys) userSecret
    fillPrimaryKey logTrace (rsPrimaryKey <$> predefinedRichKeys) userSecretWithVss
  where
    predefinedRichKeys :: Maybe RichSecrets
    predefinedRichKeys = do
        i <- devGenesisSecretI
        case mGeneratedSecrets of
            Nothing -> error
                $  "devGenesisSecretI is specified, but GeneratedSecrets are "
                <> "missing from Genesis.Config. GenesisInitializer might be "
                <> "incorrectly specified."
            Just generatedSecrets -> gsRichSecrets generatedSecrets ^? ix i

-- Make sure UserSecret contains a primary key.
fillPrimaryKey ::
       (MonadIO m)
    => Trace m Text
    -> Maybe SecretKey
    -> UserSecret
    -> m (SecretKey, UserSecret)
fillPrimaryKey logTrace = fillUserSecretPart logTrace (snd <$> keyGen) usPrimKey "signing key"

-- Make sure UserSecret contains a VSS key.
fillUserSecretVSS ::
       (MonadIO m)
    => Trace m Text
    -> Maybe VssKeyPair
    -> UserSecret
    -> m (VssKeyPair, UserSecret)
fillUserSecretVSS logTrace = fillUserSecretPart logTrace vssKeyGen usVss "VSS keypair"

-- Make sure UserSecret contains something.
fillUserSecretPart ::
       (MonadIO m)
    => Trace m Text
    -> (forall n. MonadRandom n =>
                      n a)
    -> (Lens' UserSecret (Maybe a))
    -> Text
    -> Maybe a
    -> UserSecret
    -> m (a, UserSecret)
fillUserSecretPart logTrace genValue l description desiredValue userSecret = do
    toSet <- getValueToSet
    let newUS = userSecret & l .~ Just toSet
    (toSet, newUS) <$ writeUserSecret newUS
  where
    getValueToSet
        | Just desired <- desiredValue = pure desired
        | Just existing <- userSecret ^. l = pure existing
        | otherwise = do
            traceWith logTrace $
                "Found no " <> description <>
                " in keyfile, generating random one..."
            liftIO (runSecureRandom genValue)
