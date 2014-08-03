{-# LANGUAGE CPP #-}

module Nix.Parser.Library ( module Nix.Parser.Library, module X ) where

import           Control.Applicative

#if USE_PARSEC

import           Control.Monad
import           Control.Monad.IO.Class
import           Data.Functor.Identity
import           Data.Text as T hiding (map)
import           Data.Text.IO as T
import           Text.Parsec as X hiding ((<|>), many, optional)
import           Text.Parsec.Expr as X
import           Text.Parsec.Text as X
import qualified Text.Parsec.Token as P
import           Text.PrettyPrint.ANSI.Leijen as X (Doc, text)

lexer :: P.GenTokenParser Text () Identity
lexer = P.makeTokenParser P.LanguageDef
    { P.commentStart    = "/*"
    , P.commentEnd      = "*/"
    , P.commentLine     = "#"
    , P.nestedComments  = True
    , P.identStart      = identStart
    , P.identLetter     = identLetter
    , P.opStart         = opStart
    , P.opLetter        = opLetter
    , P.reservedNames   = reservedNames
    , P.reservedOpNames = []
    , P.caseSensitive   = True
    }

parens :: Parser a -> Parser a
parens = P.parens lexer

brackets :: Parser a -> Parser a
brackets = P.brackets lexer

braces :: Parser a -> Parser a
braces = P.braces lexer

identifier :: Parser Text
identifier = pack <$> P.identifier lexer

reserved :: String -> Parser ()
reserved = P.reserved lexer

reservedOp :: String -> Parser ()
reservedOp = P.reservedOp lexer

decimal :: Parser Integer
decimal = read <$> some digit

whiteSpace :: Parser ()
whiteSpace = P.whiteSpace lexer

data Result a = Success a
              | Failure Doc

parseFromFileEx :: MonadIO m => Parser a -> FilePath -> m (Result a)
parseFromFileEx p path =
    (either (Failure . text . show) Success . parse p path)
        `liftM` liftIO (T.readFile path)

parseFromString :: Parser a -> String -> Result a
parseFromString p = either (Failure . text . show) Success . parse p "<string>" . pack

#else

import Data.Char
import Data.List (nub)
import Data.Text hiding (map)
import Text.Parser.Expression as X
import Text.Parser.LookAhead as X
import Text.Parser.Token.Highlight
import Text.Trifecta as X hiding (whiteSpace, symbol, symbolic, parseString)
import Text.Trifecta (parseString)
import Text.Trifecta.Delta

import qualified Data.HashSet as HashSet

identStyle :: IdentifierStyle Parser
identStyle = IdentifierStyle
  { _styleName = "nix identifier"
  , _styleStart = identStart
  , _styleLetter = identLetter
  , _styleReserved = HashSet.fromList reservedNames
  , _styleHighlight = Identifier
  , _styleReservedHighlight = ReservedIdentifier
  }

identifier :: Parser Text
identifier = ident identStyle

reserved :: String -> Parser Text
reserved n = pack n <$ reserve identStyle n

reservedOp :: String -> Parser Text
reservedOp o = token $ try $ pack o <$
  highlight ReservedOperator (string o) <* (notFollowedBy opLetter <?> "end of " ++ o)

-----------------------------------------------------------
-- White space & symbols
-----------------------------------------------------------

lexeme :: (CharParsing m, Monad m) => m b -> m b
lexeme p = do{ x <- p; whiteSpace; return x  }

whiteSpace :: (CharParsing m, Monad m) => m ()
whiteSpace =
    skipMany (simpleSpace <|> oneLineComment <|> multiLineComment <?> "")

simpleSpace :: CharParsing m => m ()
simpleSpace = skipSome (satisfy isSpace)

oneLineComment :: (CharParsing m, Monad m) => m ()
oneLineComment =
    do{ _ <- try (string "#")
      ; skipMany (satisfy (/= '\n'))
      ; return ()
      }

multiLineComment :: (CharParsing m, Monad m) => m ()
multiLineComment =
    do { _ <- try (string "/*")
       ; inComment
       }

inComment :: (CharParsing m, Monad m) => m ()
inComment
    | True      = inCommentMulti
    | otherwise = inCommentSingle

inCommentMulti :: (CharParsing m, Monad m) => m ()
inCommentMulti
    =   do{ _ <- try (string "*/") ; return () }
    <|> do{ multiLineComment                    ; inCommentMulti }
    <|> do{ skipSome (noneOf startEnd)          ; inCommentMulti }
    <|> do{ _ <- oneOf startEnd                  ; inCommentMulti }
    <?> "end of comment"
    where
      startEnd   = nub ("*/" ++ "/*")

inCommentSingle :: (CharParsing m, Monad m) => m ()
inCommentSingle
    =   do{ _ <- try (string "*/"); return () }
    <|> do{ skipSome (noneOf startEnd)         ; inCommentSingle }
    <|> do{ _ <- oneOf startEnd                 ; inCommentSingle }
    <?> "end of comment"
    where
      startEnd   = nub ("*/" ++ "/*")

parseFromString :: Parser a -> String -> Result a
parseFromString p = parseString p (Directed "<string>" 0 0 0 0)

#endif

opStart :: Parser Char
opStart = oneOf ":!#$%&*+./<=>?@\\^|-~"

opLetter :: Parser Char
opLetter = oneOf "@"

identStart :: Parser Char
identStart = letter <|> char '_'

identLetter :: Parser Char
identLetter = alphaNum <|> oneOf "_'-"

reservedNames :: [String]
reservedNames =
    [ "let", "in"
    , "if", "then", "else"
    , "true", "false"
    , "null"
    , "assert"
    , "with"
    , "rec"
    , "inherit"
    , "or"
    ]

stopWords :: Parser ()
stopWords = () <$
    (whiteSpace *> (reserved "in" <|> reserved "then" <|> reserved "else"))

someTill :: Parser a -> Parser end -> Parser [a]
someTill p end = go
  where
    go   = (:) <$> p <*> scan
    scan = (end *> return []) <|>  go

symbolic :: Char -> Parser Char
symbolic c = char c <* whiteSpace
