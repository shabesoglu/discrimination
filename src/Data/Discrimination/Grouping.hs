{-# LANGUAGE CPP #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE Trustworthy #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE RoleAnnotations #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ParallelListComp #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -fno-cse -fno-full-laziness #-}

module Data.Discrimination.Grouping
  ( Group(..)
  , Grouping(..)
  , Grouping1(..)
  -- * Combinators
  , nub, nubWith
  , group, groupWith
  , groupingEq
  , runGroup
  -- * Internals
--  , groupingBag
--  , groupingSet
  , groupingShort
  , groupingNat
  ) where

-- import Control.Arrow
import Control.Monad hiding (mapM_)
import Control.Monad.Primitive
import Control.Monad.ST
-- import Data.Bits
import Data.Complex
-- import Data.Discrimination.Internal
import Data.Foldable hiding (concat)
-- import Data.Functor
import Data.Functor.Compose
import Data.Functor.Contravariant
import Data.Functor.Contravariant.Divisible
import Data.Functor.Contravariant.Generic
import Data.Int
import Data.Monoid hiding (Any)
import Data.Primitive.MutVar
import Data.Promise
import Data.Proxy
import Data.Ratio
import Data.Typeable
import qualified Data.Vector.Mutable as UM
import Data.Void
import Data.Word
import Prelude hiding (read, concat, mapM_)

-- | Productive Stable Unordered Discriminator

newtype Group a = Group
  { getGroup :: forall m b. PrimMonad m
             => (b -> m (b -> m ())) -> m (a -> b -> m ())
  } deriving Typeable

-- #ifndef HLINT
-- type role Group representational
-- #endif

instance Contravariant Group where
  contramap f m = Group $ \k -> do
    g <- getGroup m k
    return (g . f)

instance Divisible Group where
  conquer = Group $ \ (k :: b -> m (b -> m ())) -> do
    v <- newMutVar undefined
    writeMutVar v $ \b -> k b >>= writeMutVar v
    return $ \ _ b -> readMutVar v >>= ($ b)

  divide f m n = Group $ \k -> do
    kbcd <- getGroup m $ \ (c, d) -> do
      kcd <- getGroup n k
      kcd c d
      return $ uncurry kcd
    return $ \ a d -> case f a of
      (b, c) -> kbcd b (c, d)

instance Decidable Group where
  choose f m n = Group $ \k -> do
    kb <- getGroup m k
    kc <- getGroup n k
    return (either kb kc . f)

  lose k = Group $ \_ -> return (absurd . k)

instance Monoid (Group a) where
  mempty = conquer
  mappend = divide (\a -> (a,a))

--------------------------------------------------------------------------------
-- Primitives
--------------------------------------------------------------------------------

groupingNat :: Int -> Group Int
groupingNat = \ n -> Group $ \k -> do
  t <- UM.replicate n Nothing
  return $ \ a b -> UM.read t a >>= \case
    Nothing -> k b >>= UM.write t a . Just
    Just k' -> k' b

groupingShort :: Group Int
groupingShort = groupingNat 65536

--------------------------------------------------------------------------------
-- * Unordered Discrimination (for partitioning)
--------------------------------------------------------------------------------

-- | 'Eq' equipped with a compatible stable unordered discriminator.
class Grouping a where
  -- | For every surjection @f@,
  --
  -- @
  -- 'contramap' f 'grouping' ≡ 'grouping'
  -- @

  grouping :: Group a
#ifndef HLINT
  default grouping :: Deciding Grouping a => Group a
  grouping = deciding (Proxy :: Proxy Grouping) grouping
#endif

instance Grouping Void where
  grouping = lose id

instance Grouping Word8 where
  grouping = contramap fromIntegral (groupingNat 256)

instance Grouping Word16 where
  grouping = contramap fromIntegral groupingShort

instance Grouping Word32 where
  grouping = undefined
{-
  grouping = Group (runs <=< runGroup groupingShort . join . runGroup groupingShort . map radices) where
    radices (x,b) = (fromIntegral x .&. 0xffff, (fromIntegral (unsafeShiftR x 16), (x,b)))
-}

instance Grouping Word64 where
  grouping = undefined
{-
  grouping = Group (runs <=< runGroup groupingShort . join . runGroup groupingShort . join
                          . runGroup groupingShort . join . runGroup groupingShort . map radices)
    where
      radices (x,b) = (fromIntegral x .&. 0xffff, (fromIntegral (unsafeShiftR x 16) .&. 0xffff
                    , (fromIntegral (unsafeShiftR x 32) .&. 0xffff, (fromIntegral (unsafeShiftR x 48)
                    , (x,b)))))
-}


instance Grouping Word where
  grouping
    | (maxBound :: Word) == 4294967295 = contramap (fromIntegral :: Word -> Word32) grouping
    | otherwise                        = contramap (fromIntegral :: Word -> Word64) grouping

instance Grouping Int8 where
  grouping = contramap (\x -> fromIntegral x + 128) (groupingNat 256)

instance Grouping Int16 where
  grouping = contramap (\x -> fromIntegral x + 32768) groupingShort

instance Grouping Int32 where
  grouping = contramap (\x -> fromIntegral (x - minBound) :: Word32) grouping

instance Grouping Int64 where
  grouping = contramap (\x -> fromIntegral (x - minBound) :: Word64) grouping

instance Grouping Int where
  grouping = contramap (\x -> fromIntegral (x - minBound) :: Word) grouping

instance Grouping Bool
instance (Grouping a, Grouping b) => Grouping (a, b)
instance (Grouping a, Grouping b, Grouping c) => Grouping (a, b, c)
instance (Grouping a, Grouping b, Grouping c, Grouping d) => Grouping (a, b, c, d)
instance Grouping a => Grouping [a]
instance Grouping a => Grouping (Maybe a)
instance (Grouping a, Grouping b) => Grouping (Either a b)
instance Grouping a => Grouping (Complex a) where
  grouping = divide (\(a :+ b) -> (a, b)) grouping grouping
instance (Grouping a, Integral a) => Grouping (Ratio a) where
  grouping = divide (\r -> (numerator r, denominator r)) grouping grouping
instance (Grouping1 f, Grouping1 g, Grouping a) => Grouping (Compose f g a) where
  grouping = getCompose `contramap` grouping1 (grouping1 grouping)

class Grouping1 f where
  grouping1 :: Group a -> Group (f a)
#ifndef HLINT
  default grouping1 :: Deciding1 Grouping f => Group a -> Group (f a)
  grouping1 = deciding1 (Proxy :: Proxy Grouping) grouping
#endif

instance Grouping1 []
instance Grouping1 Maybe
instance Grouping a => Grouping1 (Either a)
instance Grouping a => Grouping1 ((,) a)
instance (Grouping a, Grouping b) => Grouping1 ((,,) a b)
instance (Grouping a, Grouping b, Grouping c) => Grouping1 ((,,,) a b c)
instance (Grouping1 f, Grouping1 g) => Grouping1 (Compose f g) where
  grouping1 f = getCompose `contramap` grouping1 (grouping1 f)
instance Grouping1 Complex where
  grouping1 f = divide (\(a :+ b) -> (a, b)) f f

-- | Valid definition for @('==')@ in terms of 'Grouping'.
groupingEq :: Grouping a => a -> a -> Bool
groupingEq a b = runST $ do
  rn <- newMutVar (0 :: Word8)
  k <- getGroup grouping $ \_ -> do
    modifyMutVar' rn (+1)
    return return
  k a ()
  k b ()
  n <- readMutVar rn
  return $ n == 2
{-# INLINE groupingEq #-}

runGroup :: Group a -> [(a,b)] -> [[b]]
runGroup (Group m) xs = runLazy (\p0 -> do
    rp <- newMutVar p0
    f <- m $ \ b -> do
      p <- readMutVar rp
      q <- promise []
      p' <- promise []
      p != (b : demand q) : demand p'
      writeMutVar rp p'
      rq <- newMutVar q
      return $ \b' -> do
        q' <- readMutVar rq
        q'' <- promise []
        q' != b' : demand q''
        writeMutVar rq q''
    mapM_ (uncurry f) xs
  ) []

--------------------------------------------------------------------------------
-- * Combinators
--------------------------------------------------------------------------------

-- | /O(n)/. Similar to 'Data.List.group', except we do not require groups to be clustered.
--
-- This combinator still operates in linear time, at the expense of storing history.
--
-- The result equivalence classes are _not_ sorted, but the grouping is stable.
--
-- @
-- 'group' = 'groupWith' 'id'
-- @
group :: Grouping a => [a] -> [[a]]
group as = runGroup grouping [(a, a) | a <- as]

-- | /O(n)/. This is a replacement for 'GHC.Exts.groupWith' using discrimination.
--
-- The result equivalence classes are _not_ sorted, but the grouping is stable.
groupWith :: Grouping b => (a -> b) -> [a] -> [[a]]
groupWith f as = runGroup grouping [(f a, a) | a <- as]

-- | /O(n)/. This upgrades 'Data.List.nub' from @Data.List@ from /O(n^2)/ to /O(n)/ by using
-- productive unordered discrimination.
--
-- @
-- 'nub' = 'nubWith' 'id'
-- 'nub' as = 'head' 'Control.Applicative.<$>' 'group' as
-- @
nub :: Grouping a => [a] -> [a]
nub = nubWith id

-- | /O(n)/. Online 'nub' with a Schwartzian transform.
--
-- @
-- 'nubWith' f as = 'head' 'Control.Applicative.<$>' 'groupWith' f as
-- @
nubWith :: Grouping b => (a -> b) -> [a] -> [a]
nubWith f xs = runLazy (\p0 -> do
    rp <- newMutVar p0
    k <- getGroup grouping $ \a -> do
      p' <- promise []
      p <- readMutVar rp
      p != a : demand p'
      writeMutVar rp p'
      return $ \ _ -> return ()
    mapM_ (\x -> k (f x) x) xs
  ) []

{-
--------------------------------------------------------------------------------
-- * Collections
--------------------------------------------------------------------------------

-- | Construct an stable unordered discriminator that partitions into equivalence classes based on the equivalence of keys as a multiset.
groupingBag :: Foldable f => Group k -> Group (f k)
groupingBag = groupingColl updateBag

-- | Construct an stable unordered discriminator that partitions into equivalence classes based on the equivalence of keys as a set.
groupingSet :: Foldable f => Group k -> Group (f k)
groupingSet = groupingColl updateSet

groupingColl :: Foldable f => ([Int] -> Int -> [Int]) -> Group k -> Group (f k)
groupingColl update r = Group $ \xss -> let
    (kss, vs)           = unzip xss
    elemKeyNumAssocs    = groupNum (toList <$> kss)
    keyNumBlocks        = runGroup r elemKeyNumAssocs
    keyNumElemNumAssocs = groupNum keyNumBlocks
    sigs                = bdiscNat (length kss) update keyNumElemNumAssocs
    yss                 = zip sigs vs
  in filter (not . null) $ grouping1 (groupingNat (length keyNumBlocks)) `runGroup` yss
-}
