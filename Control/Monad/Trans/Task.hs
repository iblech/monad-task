{-# LANGUAGE GADTs, 
             UndecidableInstances, 
             NoMonomorphismRestriction, 
             GeneralizedNewtypeDeriving, 
             MultiParamTypeClasses, 
             FlexibleInstances #-}

module Control.Monad.Trans.Task 
  ( -- * Task monad transformer
    TaskT (..)
    -- * Trace of a base monad
  , Trace (..)
  , runTrace
    -- * Task functions
  , taskToTrace
  , runTask
  ) where

import Control.Applicative
import Control.Monad.Reader.Class
import Control.Monad.State.Class
import Control.Monad.IO.Class
import Control.Monad.Trans
import Control.Monad.Trans.Cont
import Control.Monad.Task.Class
import Data.Either (partitionEithers)

-- | A @Trace m e@ represents the control flow of a mult-threaded task monad
--   defined over a base monad @m@ and event type @e@. 
data Trace m e where
  EXIT   :: Trace m e
  RET    :: Trace m e
  YIELD  :: m (Trace m e) -> Trace m e
  FORK   :: m (Trace m e) -> m (Trace m e) -> Trace m e
  WATCH  :: (e -> Maybe v) -> (v -> m (Trace m e)) -> Trace m e 
  SIGNAL :: e -> m (Trace m e) -> Trace m e

-- | @runTrace@ runs a trace to its completion in the base monad with a simple 
--   round-robin scheduler.
runTrace :: Monad m => m (Trace m e) -> m ()
runTrace prog = loop [prog] []
  where
    loop [] _ = return ()
    loop (m:ms) ss = m >>= step
      where
        step EXIT         = return ()
        step RET          = loop ms ss
        step (YIELD t)    = loop (ms ++ [t]) ss
        step (FORK t1 t2) = loop (t1:t2:ms) ss
        step (WATCH f g)  = loop ms (WATCH f g : ss)
        step (SIGNAL e t) = loop (ms' ++ [t] ++ ms) ss'
          where (ms', ss') = partitionEithers evs
                evs = [ maybe (Right x) (Left . g) (f e) | x@(WATCH f g) <- ss ]

-- | Task monad transformer.
newtype TaskT e m a 
  = TaskT { runTaskT :: ContT (Trace m e) m a }
  deriving (Functor, Applicative, MonadIO)

-- | @tasktoTrace@ CPS-converts a task monad into a trace in its base monad. 
taskToTrace :: Monad m => TaskT e m a -> m (Trace m e) 
taskToTrace (TaskT (ContT f)) = f (\_ -> return RET)

-- | @runTask@ runs a task monad until to its completion, i.e., no more active
--   tasks to run, or until it exits.
--
-- * @'runTask' = 'runTrace' . 'taskToTrace'@
runTask :: Monad m => TaskT e m a -> m ()
runTask = runTrace . taskToTrace

instance Monad m => Monad (TaskT e m) where
  return = TaskT . return
  (>>=) m f = TaskT $ runTaskT m >>= runTaskT . f
  fail _ = TaskT $ ContT $ \_ -> return EXIT 

instance MonadTrans (TaskT e) where
  lift = TaskT . lift

instance MonadReader s m => MonadReader s (TaskT e m) where
  ask = TaskT ask
  local f = TaskT . local f . runTaskT 

instance MonadState s m => MonadState s (TaskT e m) where
  get = TaskT get
  put = TaskT . put

instance Monad m => MonadTask e (TaskT e m) where
  exit     = TaskT $ ContT $ \_ -> return EXIT
  yield    = TaskT $ ContT $ return . YIELD . ($())
  fork p   = TaskT $ ContT $ return . FORK (taskToTrace p) . ($())
  watch f  = TaskT $ ContT $ return . WATCH f 
  signal e = TaskT $ ContT $ return . SIGNAL e . ($())

