{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
module Parsers
    ( Timing(..)
    , Timer(..)
    , Property(..)
    , conduitParse
    , property
    , timing
    ) where

import Control.Applicative ((<|>))
import Control.Monad.Catch (MonadThrow)
import Data.Text (Text)
import Data.Attoparsec.Text
import Data.Conduit (ConduitT, (.|))
import qualified Data.Conduit.Combinators as C
import Data.Conduit.Attoparsec (conduitParser)

conduitParse :: MonadThrow m => Parser a -> ConduitT Text a m ()
conduitParse p = conduitParser p .| C.map snd

data Timing
    = Timing
    { name :: Text
    , minTime :: Double
    , avgTime :: Double
    , maxTime :: Double
    , stddev :: Double
    } deriving (Show, Eq, Ord)

data Timer = TotalTiming Timing | StepTiming Int Timing
    deriving (Show, Eq)

data Property
    = GraphProperty Text Double
    | StepProperty Int Text Double
    | Prediction Int Int
    deriving (Show, Eq)

property :: Parser Property
property = (graphProp <|> stepProp <|> prediction) <* endOfLine
  where
    graphProp :: Parser Property
    graphProp = do
        string "graph:"
        name <- takeWhile1 (/=':') <* char ':'
        GraphProperty name <$> double

    stepProp :: Parser Property
    stepProp = do
        string "step:"
        step <- signed decimal <* char ':'
        name <- takeWhile1 (/=':') <* char ':'
        StepProperty step name <$> double

    prediction :: Parser Property
    prediction = do
        string "prediction:"
        Prediction <$> signed decimal <* char ':' <*> signed decimal

timing :: Parser Timer
timing = stepTime <|> totalTime
  where
    stepTime :: Parser Timer
    stepTime = StepTiming <$> decimal <* char ':' <*> timer

    totalTime :: Parser Timer
    totalTime = TotalTiming <$> timer

    timer :: Parser Timing
    timer = do
        name <- takeWhile1 (/=':')
        char ':'
        minTime <- double <* char ' '
        avgTime <- double <* char ' '
        maxTime <- double <* char ' '
        stddev <- double <* endOfLine
        return Timing{..}