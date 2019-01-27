{-# LANGUAGE FlexibleContexts, FlexibleInstances, RankNTypes, RecordWildCards, ScopedTypeVariables, TypeFamilies #-}

module Main where

import Language.Oberon (parseAndResolveModule, resolvePosition, resolvePositions)
import Language.Oberon.AST (Module(..), StatementSequence, Statement, Expression)
import qualified Language.Oberon.Grammar as Grammar
import qualified Language.Oberon.Resolver as Resolver
import qualified Language.Oberon.Pretty ()

import qualified Transformation.Rank2 as Rank2
import qualified Transformation.Deep as Deep

import Data.Text.Prettyprint.Doc (Pretty(pretty))
import Data.Text.Prettyprint.Doc.Util (putDocW)

import Control.Monad
import Data.Data (Data)
import Data.Either.Validation (Validation(..), validationToEither)
import Data.Functor.Identity (Identity)
import Data.Functor.Compose (Compose, getCompose)
import Data.List.NonEmpty (NonEmpty((:|)))
import qualified Data.Map.Lazy as Map
import Data.Maybe (fromMaybe)
import Data.Monoid ((<>))
import Data.Text (Text, unpack)
import Data.Text.IO (getLine, readFile, getContents)
import qualified Data.Text.IO as Text
import Data.Typeable (Typeable)
import Options.Applicative
import Text.Grampa (Ambiguous, Grammar, ParseResults, parseComplete, failureDescription)
import qualified Text.Grampa.ContextFree.LeftRecursive as LeftRecursive
import ReprTree
import System.FilePath (FilePath, takeDirectory)

import Prelude hiding (getLine, getContents, readFile)

data GrammarMode = TypeCheckedModuleMode | ModuleWithImportsMode | ModuleMode | AmbiguousModuleMode | DefinitionMode
                 | StatementsMode | StatementMode | ExpressionMode
    deriving Show

data Output = Plain | Pretty Int | Tree
            deriving Show

data Opts = Opts
    { optsMode        :: GrammarMode
    , optsOberon2     :: Bool
    , optsIndex       :: Int
    , optsOutput      :: Output
    , optsInclude     :: Maybe FilePath
    , optsFile        :: Maybe FilePath
    } deriving Show

main :: IO ()
main = execParser opts >>= main'
  where
    opts = info (helper <*> p)
        ( fullDesc
       <> progDesc "Parse an Oberon file, or parse interactively"
       <> header "Oberon parser")

    p :: Parser Opts
    p = Opts
        <$> mode
        <*> (switch (long "oberon2"))
        <*> (option auto (long "index" <> help "Index of ambiguous parse" <> showDefault <> value 0 <> metavar "INT"))
        <*> (Pretty <$> option auto (long "pretty" <> help "Pretty-print output" <> metavar "WIDTH")
             <|> Tree <$ switch (long "tree" <> help "Print the output as an abstract syntax tree")
             <|> pure Plain)
        <*> optional (strOption (short 'i' <> long "include" <> metavar "DIRECTORY"
                                 <> help "Where to look for imports"))
        <*> optional (strArgument
            ( metavar "FILE"
              <> help "Oberon file to parse"))

    mode :: Parser GrammarMode
    mode = TypeCheckedModuleMode <$ switch (long "type-checked-module")
       <|> ModuleWithImportsMode <$ switch (long "module-with-imports")
       <|> ModuleMode          <$ switch (long "module")
       <|> AmbiguousModuleMode <$ switch (long "module-ambiguous")
       <|> DefinitionMode      <$ switch (long "definition")
       <|> StatementMode       <$ switch (long "statement")
       <|> StatementsMode      <$ switch (long "statements")
       <|> ExpressionMode      <$ switch (long "expression")

main' :: Opts -> IO ()
main' Opts{..} =
    case optsFile of
        Just file -> (if file == "-" then getContents else readFile file)
                     >>= case optsMode
                         of TypeCheckedModuleMode ->
                              \source-> parseAndResolveModule True optsOberon2
                                (fromMaybe (takeDirectory file) optsInclude) source
                              >>= succeed optsOutput
                            ModuleWithImportsMode ->
                              \source-> parseAndResolveModule False optsOberon2
                                (fromMaybe (takeDirectory file) optsInclude) source
                              >>= succeed optsOutput
                            ModuleMode ->
                              go (Resolver.resolveModule predefined mempty) Grammar.module_prod chosenGrammar file
                            DefinitionMode ->
                              go (Resolver.resolveModule predefined mempty) Grammar.module_prod
                                 Grammar.oberonDefinitionGrammar file
                            AmbiguousModuleMode ->
                              go pure Grammar.module_prod chosenGrammar file
                            _ -> error "A file usually contains a whole module."

        Nothing ->
            forever $
            getLine >>=
            case optsMode of
                ModuleMode          -> go (Resolver.resolveModule predefined mempty) Grammar.module_prod
                                          chosenGrammar "<stdin>"
                AmbiguousModuleMode -> go pure Grammar.module_prod chosenGrammar "<stdin>"
                DefinitionMode      -> go (Resolver.resolveModule predefined mempty) Grammar.module_prod
                                          Grammar.oberonDefinitionGrammar "<stdin>"
                StatementMode       -> go pure Grammar.statement chosenGrammar "<stdin>"
                StatementsMode      -> go pure Grammar.statementSequence chosenGrammar "<stdin>"
                ExpressionMode      -> \src-> case getCompose ((resolvePosition src . (resolvePositions src <$>))
                                                               <$> Grammar.expression (parseComplete chosenGrammar src))
                                              of Right [x] -> succeed optsOutput (pure x)
                                                 Right l -> putStrLn ("Ambiguous: " ++ show optsIndex ++ "/"
                                                                      ++ show (length l) ++ " parses")
                                                            >> succeed optsOutput (pure $ l !! optsIndex)
                                                 Left err -> Text.putStrLn (failureDescription src err 4)
  where
    chosenGrammar = if optsOberon2 then Grammar.oberon2Grammar else Grammar.oberonGrammar
    predefined = if optsOberon2 then Resolver.predefined2 else Resolver.predefined
    
    go :: (Show a, Data a, Pretty a, a ~ t f f,
           Deep.Functor (Rank2.Map Grammar.NodeWrap NodeWrap) t Grammar.NodeWrap NodeWrap) =>
          (t NodeWrap NodeWrap -> Validation (NonEmpty Resolver.Error) a)
       -> (forall p. Grammar.OberonGrammar Grammar.NodeWrap p -> p (t Grammar.NodeWrap Grammar.NodeWrap))
       -> (Grammar (Grammar.OberonGrammar Grammar.NodeWrap) LeftRecursive.Parser Text)
       -> String -> Text -> IO ()
    go resolve production grammar filename contents =
       case getCompose (resolvePositions contents <$> production (parseComplete grammar contents))
       of Right [x] -> succeed optsOutput (resolve x)
          Right l -> putStrLn ("Ambiguous: " ++ show optsIndex ++ "/" ++ show (length l) ++ " parses")
                     >> succeed optsOutput (resolve $ l !! optsIndex)
          Left err -> Text.putStrLn (failureDescription contents err 4)

type NodeWrap = Compose ((,) Int) Ambiguous

succeed out x = either reportFailure showSuccess (validationToEither x)
   where reportFailure (Resolver.UnparseableModule err :| []) = Text.putStrLn err
         reportFailure errs = print errs
         showSuccess = case out
                       of Pretty width -> putDocW width . pretty
                          Tree -> putStrLn . reprTreeString
                          Plain -> print

instance Pretty (Module NodeWrap NodeWrap) where
   pretty _ = error "Disambiguate before pretty-printing"
instance Pretty (StatementSequence NodeWrap NodeWrap) where
   pretty _ = error "Disambiguate before pretty-printing"
instance Pretty (NodeWrap (Statement NodeWrap NodeWrap)) where
   pretty _ = error "Disambiguate before pretty-printing"
instance Pretty (Statement NodeWrap NodeWrap) where
   pretty _ = error "Disambiguate before pretty-printing"
instance Pretty (Expression NodeWrap NodeWrap) where
   pretty _ = error "Disambiguate before pretty-printing"
instance Pretty (NodeWrap (Expression NodeWrap NodeWrap)) where
   pretty _ = error "Disambiguate before pretty-printing"
