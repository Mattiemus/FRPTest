module Test.FRP.TreeGen where

import Data.Tree

import System.Random

import Test.FRP.General
import Test.FRP.Tree
import Test.FRP.Path

{--------------------------------------------------------------------
    Generator state
--------------------------------------------------------------------}

-- |State container for a input generator
data GenState g
    = GenState {
         genRandom :: g -- ^Random number generator
        ,genClock :: TimePoint -- ^The current time
        ,genClockDelta :: TimeSpan -- ^The time between two generated values
    }

-- |Constructs a default state using a given random number generator
defaultGenState :: g -> GenState g
defaultGenState gen = GenState { genRandom = gen, genClock = 0.0, genClockDelta = 0.1 }

{--------------------------------------------------------------------
    Tree generator
--------------------------------------------------------------------}

-- |A tree generator is a function that takes a state and returns a value, a new state, and a function to extend the tree generated by the next step
data Gen g a b = Gen { unGen :: GenState g -> (b, [ProgTree (Value a)] -> [ProgTree (Value a)], GenState g) }

instance Functor (Gen g a) where
    fmap f (Gen g) = Gen $ \state ->
        let (x, tree, nextState) = g state
        in (f x, tree, nextState)

instance Applicative (Gen g a) where
    pure x = Gen $ \state -> (x, id, state)
    (Gen fs) <*> (Gen xs) = Gen $ \state ->
        let (f, fTree, fState) = fs state
            (x, xTree, xState) = xs fState
        in (f x, fTree . xTree, xState)

instance Monad (Gen g a) where
    return = pure
    Gen g >>= f = Gen $ \state ->
        let (x, treeA, gState) = g state
            (y, treeB, fState) = unGen (f x) gState
        in (y, treeA . treeB, fState)

{--------------------------------------------------------------------
    Execution
--------------------------------------------------------------------}

-- |Runs a generator using the default generator state, and the standard number generator
runDefaultGen :: Gen StdGen a b -> IO (b, [ProgTree (Value a)])
runDefaultGen (Gen g) = do
    -- Create the state
    randGen <- newStdGen
    let state = defaultGenState randGen
        (x, tree, _) = g state
        resultTree = tree []
    return (x, resultTree)

-- |Runs the generator as per `runDefaultGen`, but ignores the output
runDefaultGen_ :: Gen StdGen a b -> IO [ProgTree (Value a)]
runDefaultGen_ gen = do
    (_, result) <- runDefaultGen gen
    return result

-- |Runs the generator as per `runDefaultGen`, then prints it. Useful for debugging.
printGeneratedTree :: Show a => Gen StdGen a b -> IO ()
printGeneratedTree gen = do
    trees <- runDefaultGen_ gen
    mapM_ putStrLn (fmap (drawTree . fmap show . unProgTree) trees)

{--------------------------------------------------------------------
    Primitive operations
--------------------------------------------------------------------}

-- |Returns the current generator state
get :: Gen g a (GenState g)
get = Gen $ \state -> (state, id, state)

-- |Updates the generator state with a new value
put :: GenState g -> Gen g a ()
put state = Gen $ const ((), id, state)

-- |Transforms the generator state using the given function
state :: (GenState g -> GenState g) -> Gen g a ()
state f = Gen $ \state -> ((), id, f state)

-- |Transforms the generator state using the given function, but also returns a value
withState :: (GenState g -> (b, GenState g)) -> Gen g a b
withState f = Gen $ \state ->
    let (x, newState) = f state
    in (x, id, newState)

-- |Gets the current clock value
getClock :: Gen g a TimePoint
getClock = withState (\s -> (genClock s, s))

-- |Sets the current clock value
setClock :: TimePoint -> Gen g a ()
setClock tp = state (\s -> s { genClock = tp })

-- |Steps the clock with the current clock delta
stepClock :: Gen g a ()
stepClock = state (\s -> s { genClock = genClock s + genClockDelta s })

-- |Sets the clock delta
setClockDelta :: TimeSpan -> Gen g a ()
setClockDelta span = state (\s -> s { genClockDelta = span })

{--------------------------------------------------------------------
    Primitive generators
--------------------------------------------------------------------}

-- |Inserts a value to the program tree at the current position
putVal :: Value a -> Gen g a ()
putVal x = Gen $ \state -> ((), addValue, state)
    where
        addValue [] = [ProgTree (pure x)]
        addValue nexts = [ProgTree (Node x (fmap unProgTree nexts))]

-- |Inserts a value to the program tree at the current position and time, then steps the clock
putValue :: a -> Gen g a ()
putValue x = do
    tp <- getClock
    putVal (Value (x, tp))
    stepClock

-- |Inserts a list of values into the program tree at the current position
putValues :: [a] -> Gen g a ()
putValues = mapM_ putValue

-- |Inserts a random value into the program tree at the current position and time, then steps the clock
putRandValue :: (RandomGen g, Random a) => Gen g a ()
putRandValue = do
    x <- withState (\s -> let (val, nextG) = random (genRandom s)
                          in (val, s { genRandom = nextG }))
    putValue x

-- |Inserts a random value into the program tree bounded by upper and lowwer values at the current position and time, then steps the clock
putRandRValue :: (RandomGen g, Random a) => a -> a -> Gen g a ()
putRandRValue min max = do
    x <- withState (\s -> let (val, nextG) = randomR (min, max) (genRandom s)
                          in (val, s { genRandom = nextG }))
    putValue x

{--------------------------------------------------------------------
    Branching generators
--------------------------------------------------------------------}

-- |Causes the program tree to branch at the current position, with the branch being generated by the given generator
branch :: Gen g a b -> Gen g a b
branch gen = Gen $ \state ->
    let (x, genTree, GenState { genRandom = rand }) = unGen gen state
    in (x, \nextTrees -> genTree [] ++ nextTrees, state { genRandom = rand })

-- |Same as `branch` but uses the same number generator for the current and new branch. 
branchForgetRand :: Gen g a b -> Gen g a b
branchForgetRand gen = Gen $ \state ->
    let (x, genTree, _) = unGen gen state
    in (x, \nextTrees -> genTree [] ++ nextTrees, state)
