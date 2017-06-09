-- |
-- Module      : Foundation.Parser
-- License     : BSD-style
-- Maintainer  : Haskell Foundation
-- Stability   : experimental
-- Portability : portable
--
-- The current implementation is mainly, if not copy/pasted, inspired from
-- `memory`'s Parser.
--
-- A very simple bytearray parser related to Parsec and Attoparsec
--
-- Simple example:
--
-- > > parse ((,,) <$> take 2 <*> element 0x20 <*> (elements "abc" *> anyElement)) "xx abctest"
-- > ParseOK "est" ("xx", 116)
--

{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE FlexibleContexts #-}

module Foundation.Parser
    ( Parser
    , parse
    , parseFeed
    , parseOnly
    , -- * Result
      Result(..)
    , ParseError(..)

    , -- * Parser source
      ParserSource(..)

    , -- * combinator
      element
    , anyElement
    , elements
    , string

    , satisfy
    , satisfy_
    , take
    , takeWhile
    , takeAll

    , skip
    , skipWhile
    , skipAll

    , (<|>)
    , many
    , some
    , optional
    , Count(..), Condition(..), repeat
    ) where

import           Control.Applicative (Alternative, empty, (<|>), many, some, optional)
import           Control.Monad (MonadPlus, mzero, mplus)

import           Foundation.Internal.Base
import           Foundation.Primitive.Types.OffsetSize
import           Foundation.Numerical
import           Foundation.Collection hiding (take)
import qualified Foundation.Collection as C
import           Foundation.String

-- Error handling -------------------------------------------------------------

-- | common parser error definition
data ParseError input
    = NotEnough (CountOf (Element input))
    | NotEnoughParseOnly
    | ExpectedElement (Element input) (Element input)
    | Expected (Chunk input) (Chunk input)
    | Satisfy (Maybe String)
  deriving (Typeable)
instance Typeable input => Exception (ParseError input)

instance Show (ParseError input) where
    show (NotEnough (CountOf sz)) = "NotEnough: missing " <> show sz <> " element(s)"
    show NotEnoughParseOnly    = "NotEnough, parse only"
    show (ExpectedElement _ _) = "Expected _ but received _"
    show (Expected _ _)        = "Expected _ but received _"
    show (Satisfy Nothing)     = "Satisfy"
    show (Satisfy (Just s))    = "Satisfy: " <> toList s

-- Results --------------------------------------------------------------------

data Result input result
    = ParseFailed (ParseError input)
    | ParseOk     (Chunk input) result
    | ParseMore   (Chunk input -> Result input result)

instance Show k => Show (Result input k) where
    show (ParseFailed err) = "Parser failed: " <> show err
    show (ParseOk _ k) = "Parser succeed: " <> show k
    show (ParseMore _) = "Parser incomplete: need more"
instance Functor (Result input) where
    fmap f r = case r of
        ParseFailed err -> ParseFailed err
        ParseOk rest a  -> ParseOk rest (f a)
        ParseMore more -> ParseMore (fmap f . more)

-- Parser Source --------------------------------------------------------------

class (Sequential input, IndexedCollection input) => ParserSource input where
    type Chunk input

    nullChunk :: input -> Chunk input -> Bool

    appendChunk :: input -> Chunk input -> input

    subChunk :: input -> Offset (Element input) -> CountOf (Element input) -> Chunk input

    spanChunk :: input -> Offset (Element input) -> (Element input -> Bool) -> (Chunk input, Offset (Element input))

endOfParserSource :: ParserSource input => input -> Offset (Element input) -> Bool
endOfParserSource l off = off .==# length l
{-# INLINE endOfParserSource #-}

-- Parser ---------------------------------------------------------------------

data NoMore = More | NoMore
  deriving (Show, Eq)

type Failure input         result = input -> Offset (Element input) -> NoMore -> ParseError input -> Result input result

type Success input result' result = input -> Offset (Element input) -> NoMore -> result'          -> Result input result

newtype Parser input result = Parser
    { runParser :: forall result'
                 . input -> Offset (Element input) -> NoMore
                -> Failure input        result'
                -> Success input result result'
                -> Result input result'
    }

instance Functor (Parser input) where
    fmap f fa = Parser $ \buf off nm err ok ->
        runParser fa buf off nm err $ \buf' off' nm' a -> ok buf' off' nm' (f a)
    {-# INLINE fmap #-}

instance ParserSource input => Applicative (Parser input) where
    pure a = Parser $ \buf off nm _ ok -> ok buf off nm a
    {-# INLINE pure #-}
    fab <*> fa = Parser $ \buf0 off0 nm0 err ok ->
        runParser  fab buf0 off0 nm0 err $ \buf1 off1 nm1 ab ->
        runParser_ fa  buf1 off1 nm1 err $ \buf2 off2 nm2 -> ok buf2 off2 nm2 . ab
    {-# INLINE (<*>) #-}

instance ParserSource input => Monad (Parser input) where
    return = pure
    {-# INLINE return #-}
    m >>= k       = Parser $ \buf off nm err ok ->
        runParser  m     buf  off  nm  err $ \buf' off' nm' a ->
        runParser_ (k a) buf' off' nm' err ok
    {-# INLINE (>>=) #-}

instance ParserSource input => MonadPlus (Parser input) where
    mzero = error "Foundation.Parser.Internal.MonadPlus.mzero"
    mplus f g = Parser $ \buf off nm err ok ->
        runParser f buf off nm (\buf' _ nm' _ -> runParser g buf' off nm' err ok) ok
    {-# INLINE mplus #-}
instance ParserSource input => Alternative (Parser input) where
    empty = error "Foundation.Parser.Internal.Alternative.empty"
    (<|>) = mplus
    {-# INLINE (<|>) #-}

runParser_ :: ParserSource input
           => Parser input result
           -> input
           -> Offset (Element input)
           -> NoMore
           -> Failure input        result'
           -> Success input result result'
           -> Result input         result'
runParser_ parser buf off NoMore err ok = runParser parser buf off NoMore err ok
runParser_ parser buf off nm     err ok
    | endOfParserSource buf off = ParseMore $ \chunk ->
        if nullChunk buf chunk
            then runParser parser buf off NoMore err ok
            else runParser parser (appendChunk buf chunk) off nm err ok
    | otherwise = runParser parser buf                    off nm err ok
{-# INLINE runParser_ #-}

-- | Run a parser on an @initial input.
--
-- If the Parser need more data than available, the @feeder function
-- is automatically called and fed to the More continuation.
parseFeed :: (ParserSource input, Monad m)
          => m (Chunk input)
          -> Parser input a
          -> input
          -> m (Result input a)
parseFeed feeder p initial = loop $ parse p initial
  where loop (ParseMore k) = feeder >>= (loop . k)
        loop r             = return r

-- | Run a Parser on a ByteString and return a 'Result'
parse :: ParserSource input
      => Parser input a -> input -> Result input a
parse p s = runParser p s 0 More failure success

failure :: input -> Offset (Element input) -> NoMore -> ParseError input -> Result input r
failure _ _ _ = ParseFailed
{-# INLINE failure #-}

success :: ParserSource input => input -> Offset (Element input) -> NoMore -> r -> Result input r
success buf off _ = ParseOk rest
  where
    !rest = subChunk buf off (length buf - offsetAsSize off)
{-# INLINE success #-}

-- | parse only the given input
--
-- The left-over `Element input` will be ignored, if the parser call for more
-- data it will be continuously fed with `Nothing` (up to 256 iterations).
--
parseOnly :: (ParserSource input, Monoid (Chunk input))
          => Parser input a
          -> input
          -> Either (ParseError input) a
parseOnly p i = case parse p i of
    ParseFailed err  -> Left err
    ParseOk     _ r  -> Right r
    ParseMore   more -> case more mempty of
        ParseFailed err -> Left err
        ParseOk     _ r -> Right r
        ParseMore   _   -> Left NotEnoughParseOnly
{-
parseOnly p i = case parseFeed (Just mempty) p i of
    Just (ParseFailed err) -> Left err
    Just (ParseOk     _ r) -> Right r
    _                      -> Left NotEnoughParseOnly
-}

-- ------------------------------------------------------------------------- --
--                              String Parser                                --
-- ------------------------------------------------------------------------- --

instance ParserSource String where
    type Chunk String = String
    nullChunk _ = null
    {-# INLINE nullChunk #-}
    appendChunk = mappend
    {-# INLINE appendChunk #-}
    subChunk c off sz = C.take sz $ C.drop (offsetAsSize off) c
    {-# INLINE subChunk #-}
    spanChunk buf off predicate =
        let c      = C.drop (offsetAsSize off) buf
            (t, _) = C.span predicate c
          in (t, off `offsetPlusE` length t)
    {-# INLINE spanChunk #-}

instance ParserSource [a] where
    type Chunk [a] = [a]
    nullChunk _ = null
    {-# INLINE nullChunk #-}
    appendChunk = mappend
    {-# INLINE appendChunk #-}
    subChunk c off sz = C.take sz $ C.drop (offsetAsSize off) c
    {-# INLINE subChunk #-}
    spanChunk buf off predicate =
        let c      = C.drop (offsetAsSize off) buf
            (t, _) = C.span predicate c
          in (t, off `offsetPlusE` length t)
    {-# INLINE spanChunk #-}

-- ------------------------------------------------------------------------- --
--                          Helpers                                          --
-- ------------------------------------------------------------------------- --

-- | Get the next `Element input` from the parser
anyElement :: ParserSource input => Parser input (Element input)
anyElement = Parser $ \buf off nm err ok ->
    case buf ! off of
        Nothing -> err buf off        nm $ NotEnough 1
        Just x  -> ok  buf (succ off) nm x
{-# INLINE anyElement #-}

element :: ( ParserSource input
           , Eq (Element input)
           , Element input ~ Element (Chunk input)
           )
        => Element input
        -> Parser input ()
element expectedElement = Parser $ \buf off nm err ok ->
    case buf ! off of
        Nothing -> err buf off nm $ NotEnough 1
        Just x | expectedElement == x -> ok  buf (succ off) nm ()
               | otherwise            -> err buf off nm $ ExpectedElement expectedElement x
{-# INLINE element #-}

elements :: ( ParserSource input, Sequential (Chunk input)
            , Element (Chunk input) ~ Element input
            , Eq (Chunk input)
            )
         => Chunk input -> Parser input ()
elements = consumeEq
  where
    consumeEq :: ( ParserSource input
                 , Sequential (Chunk input)
                 , Element (Chunk input) ~ Element input
                 , Eq (Chunk input)
                 )
              => Chunk input -> Parser input ()
    consumeEq expected = Parser $ \buf off nm err ok ->
      if endOfParserSource buf off
        then
          err buf off nm $ NotEnough lenE
        else
          let !lenI = sizeAsOffset (length buf) - off
           in if lenI >= lenE
             then
              let a = subChunk buf off lenE
               in if a == expected
                    then ok buf (off + sizeAsOffset lenE) nm ()
                    else err buf off nm $ Expected expected a
             else
              let a = subChunk buf off lenI
                  (e', r) = splitAt lenI expected
               in if a == e'
                    then runParser_ (consumeEq r) buf (off + sizeAsOffset lenI) nm err ok
                    else err buf off nm $ Expected e' a
      where
        !lenE = length expected
    {-# NOINLINE consumeEq #-}
{-# INLINE elements #-}

-- | take one element if satisfy the given predicate
satisfy :: ParserSource input => Maybe String -> (Element input -> Bool) -> Parser input (Element input)
satisfy desc predicate = Parser $ \buf off nm err ok ->
    case buf ! off of
        Nothing -> err buf off nm $ NotEnough 1
        Just x | predicate x -> ok  buf (succ off) nm x
               | otherwise   -> err buf off nm $ Satisfy desc
{-# INLINE satisfy #-}

-- | take one element if satisfy the given predicate
satisfy_ :: ParserSource input => (Element input -> Bool) -> Parser input (Element input)
satisfy_ = satisfy Nothing
{-# INLINE satisfy_ #-}

take :: ( ParserSource input
        , Sequential (Chunk input)
        , Element input ~ Element (Chunk input)
        )
     => CountOf (Element (Chunk input))
     -> Parser input (Chunk input)
take n = Parser $ \buf off nm err ok ->
    let lenI = sizeAsOffset (length buf) - off
     in if endOfParserSource buf off && n > 0
       then err buf off nm $ NotEnough n
       else if n <= lenI
         then let t = subChunk buf off n
               in ok buf (off + sizeAsOffset n) nm t
         else let h = subChunk buf off lenI
               in runParser_ (take $ n - lenI) buf (sizeAsOffset lenI) nm err $
                    \buf' off' nm' t -> ok buf' off' nm' (h <> t)

takeWhile :: ( ParserSource input, Sequential (Chunk input)
             )
          => (Element input -> Bool)
          -> Parser input (Chunk input)
takeWhile predicate = Parser $ \buf off nm err ok ->
    if endOfParserSource buf off
      then ok buf off nm mempty
      else let (b1, off') = spanChunk buf off predicate
            in if endOfParserSource buf off'
                  then runParser_ (takeWhile predicate) buf off' nm err
                          $ \buf' off'' nm' b1T -> ok buf' off'' nm' (b1 <> b1T)
                  else ok buf off' nm b1

-- | Take the remaining elements from the current position in the stream
takeAll :: (ParserSource input, Sequential (Chunk input)) => Parser input (Chunk input)
takeAll = getAll >> returnBuffer
  where
    returnBuffer :: ParserSource input => Parser input (Chunk input)
    returnBuffer = Parser $ \buf off nm _ ok ->
        let !lenI = length buf
            !off' = sizeAsOffset lenI
            !sz   = off' - off
         in ok buf off' nm (subChunk buf off sz)
    {-# INLINE returnBuffer #-}

    getAll :: (ParserSource input, Sequential (Chunk input)) => Parser input ()
    getAll = Parser $ \buf off _ err ok -> ParseMore $ \nextChunk ->
      if nullChunk buf nextChunk
          then ok buf off NoMore ()
          else runParser getAll (appendChunk buf nextChunk) off More err ok
    {-# NOINLINE getAll #-}
{-# INLINE takeAll #-}

skip :: ParserSource input => CountOf (Element input) -> Parser input ()
skip n = Parser $ \buf off nm err ok ->
    let lenI = sizeAsOffset (length buf) - off
     in if endOfParserSource buf off && n > 0
       then err buf off nm $ NotEnough n
       else if n <= lenI
         then ok buf (off + sizeAsOffset n) nm ()
         else runParser_ (skip $ n - lenI) buf (sizeAsOffset lenI) nm err ok

skipWhile :: ( ParserSource input, Sequential (Chunk input)
             )
          => (Element input -> Bool)
          -> Parser input ()
skipWhile predicate = Parser $ \buf off nm err ok ->
    if endOfParserSource buf off
      then ok buf off nm ()
      else let (_, off') = spanChunk buf off predicate
            in if endOfParserSource buf off'
                  then runParser_ (skipWhile predicate) buf off' nm err ok
                  else ok buf off' nm ()

-- | consume every chunk of the stream
--
skipAll :: (ParserSource input, Collection (Chunk input)) => Parser input ()
skipAll = flushAll
  where
    flushAll :: (ParserSource input, Collection (Chunk input)) => Parser input ()
    flushAll = Parser $ \buf off nm err ok -> ParseMore $ \nextChunk ->
      if null nextChunk
          then ok buf (sizeAsOffset $ length buf) NoMore ()
          else runParser flushAll buf off nm err ok
    {-# NOINLINE flushAll #-}
{-# INLINE skipAll #-}

string :: String -> Parser String ()
string = elements
{-# INLINE string #-}

data Count = Never | Once | Twice | Other Int
  deriving (Show)
instance Enum Count where
    toEnum 0 = Never
    toEnum 1 = Once
    toEnum 2 = Twice
    toEnum n
        | n > 2 = Other n
        | otherwise = Never
    fromEnum Never = 0
    fromEnum Once = 1
    fromEnum Twice = 2
    fromEnum (Other n) = n
    succ Never = Once
    succ Once = Twice
    succ Twice = Other 3
    succ (Other n)
        | n == 0 = Once
        | n == 1 = Twice
        | otherwise = Other (succ n)
    pred Never = Never
    pred Once = Never
    pred Twice = Once
    pred (Other n)
        | n == 2 = Once
        | n == 3 = Twice
        | otherwise = Other (pred n)

data Condition = Exactly Count
               | Between Count Count
  deriving (Show)

shouldStop :: Condition -> Bool
shouldStop (Exactly   Never) = True
shouldStop (Between _ Never) = True
shouldStop _                 = False

canStop :: Condition -> Bool
canStop (Exactly Never)   = True
canStop (Between Never _) = True
canStop _                 = False

decrement :: Condition -> Condition
decrement (Exactly n)   = Exactly (pred n)
decrement (Between a b) = Between (pred a) (pred b)

-- | repeat the given Parser a given amount of time
--
-- If you know you want it to exactly perform a given amount of time:
--
-- ```
-- repeat (Exactly Twice) (element 'a')
-- ```
--
-- If you know your parser must performs from 0 to 8 times:
--
-- ```
-- repeat (Between Never (Other 8))
-- ```
--
-- *This interface is still WIP* but went handy when writting the IPv4/IPv6
-- parsers.
--
repeat :: ParserSource input => Condition -> Parser input a -> Parser input [a]
repeat c p
    | shouldStop c = return []
    | otherwise = do
        ma <- optional p
        case ma of
            Nothing | canStop c -> return []
                    | otherwise -> fail $ "Not enough..." <> show c
            Just a -> (:) a <$> repeat (decrement c) p
