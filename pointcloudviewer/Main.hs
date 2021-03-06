{-# LANGUAGE CPP #-}
{-# LANGUAGE NamedFieldPuns, RecordWildCards, LambdaCase, MultiWayIf, ScopedTypeVariables, TypeSynonymInstances, ParallelListComp #-}
{-# LANGUAGE DeriveGeneric, StandaloneDeriving, FlexibleContexts, TypeOperators, DeriveDataTypeable #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

-- | Design notes:
--
-- * All matrices are right-multiplied: `v' = x .* A`.
module Main where

import           Control.Applicative
import           Control.Concurrent
import           Control.Exception (assert, try)
import           Control.Monad
import           Data.Attoparsec.ByteString.Char8 (parseOnly, sepBy1', double, endOfLine, skipSpace)
import           Data.Bits (unsafeShiftR)
import qualified Data.ByteString as BS
import           Data.Foldable (for_)
import           Data.IORef
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Maybe
import           Data.Int (Int64)
import           Data.List (find, intercalate, sortBy, maximumBy, (\\))
import           Data.Ord (comparing)
import           Data.Time.Clock.POSIX (getPOSIXTime)
import           Data.Typeable
import qualified Data.Packed.Matrix as Matrix
import qualified Numeric.Container as Matrix
import qualified Numeric.LinearAlgebra.Algorithms as Matrix
import           Data.Packed.Matrix ((><))
import qualified Data.Packed.Vector as HmatrixVec
import           Data.SafeCopy
import           Data.Serialize.Get (runGet)
import           Data.Serialize.Put (runPut)
import qualified Data.Vect.Double as Vect.Double
import           Data.Vect.Float hiding (Vector)
import           Data.Vect.Float.Util.Quaternion
import           Data.Vector.Storable (Vector, (!))
import qualified Data.Vector.Storable as V
import           Data.Word
import           Foreign.C.Types (CInt)
import           Foreign.Marshal.Alloc (alloca)
import           Foreign.Ptr (Ptr, nullPtr)
import           Foreign.Storable (peek)
import           Foreign.Store (Store(..), newStore, lookupStore, readStore, deleteStore)
import           GHC.Generics
import           Graphics.GLUtil
import           Graphics.UI.GLUT hiding (Plane, Normal3)
import           Linear (V3(..))
import qualified PCD.Data as PCD
import qualified PCD.Point as PCD
import           System.Directory (createDirectoryIfMissing)
import           System.Endian (fromBE32)
import           System.FilePath ((</>), takeFileName, takeDirectory)
import           System.Random (randomRIO)
import           System.SelfRestart (forkSelfRestartExePollWithAction)
import           System.IO (hPutStrLn, stderr)
import           Text.Printf (printf)

import           FitCuboidBFGS hiding (main)
import           GroupConnectedComponents (groupConnectedComponents)
import           HmatrixUtils (safeLinearSolve)
import           TranslationOptimizer (lstSqDistances)
import           HoniHelper (takeDepthSnapshot)
import           VectorUtil (kthLargestBy)


-- Things needed to `show` the Generic representation of our `State`,
-- which we use to check if the State type changed when doing hot code
-- reloading in in-place restarts in ghci.
#if __GLASGOW_HASKELL__ <= 706
deriving instance Show (V1 p)
deriving instance Show (U1 p)
deriving instance (Show c) => Show (K1 i c p)
deriving instance Show (f p) => Show (M1 i c f p)
deriving instance (Show (f p), Show (g p)) => Show ((f :*:g) p)
deriving instance (Show (f p), Show (g p)) => Show ((f :+:g) p)
deriving instance Show D
deriving instance Show C
deriving instance Show S
#endif

instance (Typeable a) => Show (IORef a) where
  show x = "IORef " ++ show (typeOf x)


-- Orphan instance so that we can derive Eq
-- (Data.Vect.Float.Instances contains this but it also brings a Num instance
-- with it which we don't want)
deriving instance Eq Vec3
deriving instance Eq Vec4
deriving instance Eq Mat4
instance Eq Proj4 where
  a == b = fromProjective a == fromProjective b
-- Orphan instance so that we can derive Ord
deriving instance Ord Vec3
deriving instance Ord Vec4
deriving instance Ord Mat4
instance Ord Proj4 where
  a `compare` b = fromProjective a `compare` fromProjective b
-- Really questionable why this isn't there already
instance Eq Normal3 where
  n1 == n2 = fromNormal n1 == fromNormal n2
instance Ord Normal3 where
  n1 `compare` n2 = fromNormal n1 `compare` fromNormal n2
deriving instance Typeable Vec3


data CloudColor
  = OneColor !(Color3 GLfloat)
  | ManyColors (Vector Vec3) -- must be same size as `cloudPoints`
  deriving (Eq, Ord, Show, Generic)

data Cloud = Cloud
  { cloudID :: !ID
  , cloudColor :: !CloudColor -- TODO maybe clean this interface up
  , cloudPoints :: Vector Vec3
  } deriving (Eq, Ord, Show, Generic, Typeable)

instance ContainsIDs Cloud where
  getIDs c = [cloudID c]
  bumpIDsBy n c = c{ cloudID = cloudID c + n }


data DragMode = Rotate | Translate
  deriving (Eq, Ord, Show, Typeable)


class ShortShow a where
  shortShow :: a -> String

  shortPrint :: a -> IO ()
  shortPrint = putStrLn . shortShow

instance ShortShow CloudColor where
  shortShow = \case
    c@OneColor{} -> show c
    ManyColors cols -> "ManyColors (" ++ show (V.length cols) ++ " points)"

instance ShortShow Cloud where
  shortShow (Cloud i col points) = "Cloud" ++ concat
    [ " ", show i, " (", shortShow col, ")"
    , " (", show (V.length points), " points)"
    ]

instance ShortShow Plane where
  shortShow (Plane i eq col bounds) = "PlaneXXX" ++ concat
    [ " ", show i, " (", show eq, ")"
    , " (", show col, ") ", show bounds
    ]

instance ShortShow Room where
  shortShow (Room i planes cloud corners _suggs proj name) = "Room" ++ concat
    [ " ", show i, " ", shortShow planes, " (", shortShow cloud, ")"
    , " ", show corners
    , " ", show proj
    , " ", name
    ]

instance ShortShow Word32 where
  shortShow = show

instance (ShortShow a, ShortShow b) => ShortShow (a, b) where
  shortShow (a,b) = "(" ++ shortShow a ++ "," ++ shortShow b ++ ")"

instance (ShortShow a) => ShortShow [a] where
  shortShow l = "[" ++ intercalate ", " (map shortShow l) ++ "]"

instance (ShortShow a, ShortShow b) => ShortShow (Map a b) where
  shortShow = shortShow . Map.toList


-- TODO make all State/TransientState fields strict so that we get an error if not initialized

-- |Application state
data State = State
  { sMouse                         :: !(IORef ( GLint, GLint ))
  , sDragMode                      :: !(IORef (Maybe DragMode))
  , sSize                          :: !(IORef ( GLint, GLint ))
  , sLookAtPoint                   :: !(IORef Vec3) -- ^ focus point around which we rotate
  , sRotUp                         :: !(IORef Float) -- ^ view angle (degrees) away from the ground plane
  , sRotY                          :: !(IORef Float) -- ^ angle (degrees) around the up axis (Y in OpenGL), orthogonal to ground plane
  , sZoom                          :: !(IORef Float)
  , queuedClouds                   :: !(IORef (Map ID Cloud))
  , sFps                           :: !(IORef Int)
  -- | Both `display` and `idle` set this to the current time after running
  , sLastLoopTime                  :: !(IORef (Maybe Int64))
  -- Things needed for hot code reloading
  , sRestartRequested              :: !(IORef Bool)
  , sGlInitialized                 :: !(IORef Bool)
  , sRestartFunction               :: !(IORef (IO ()))
  -- Object picking
  , sPickingDisabled               :: !(IORef Bool)
  , sPickObjectAt                  :: !(IORef (Maybe ((Int,Int), Maybe ID -> IO ())))
  , sUnderCursor                   :: !(IORef (Maybe ID))
  , sDebugPickingDrawVisible       :: !(IORef Bool)
  , sDebugPickingTiming            :: !(IORef Bool)
  -- Room optimisation settings
  , sWallThickness                 :: !(IORef Float)
  -- Displaying options
  , sDisplayPlanes                 :: !(IORef Bool)
  , sDisplayClouds                 :: !(IORef Bool)
  , sPointSize                     :: !(IORef Float)
  -- Corner suggestion options
  , sSuggestionCutoffFactor        :: !(IORef Float)
  -- Wall moving
  , sWallMoveStep                  :: !(IORef Float) -- ^ How many m to move into the direction
  -- Visual debugging
  , sDebugProjectPlanePointsToEq   :: !(IORef Bool)
  -- Transient state
  , transient                      :: !(TransientState)
  } deriving (Generic)

data TransientState = TransientState
  { sNextID                        :: !(IORef ID)
  , sPickingMode                   :: !(IORef Bool)
  , sAllocatedClouds               :: !(IORef (Map ID (Cloud, BufferObject, Maybe BufferObject))) -- second is for colours
  , sPlanes                        :: !(IORef (Map ID Plane))
  , sSelectedPlanes                :: !(IORef [ID])
  , sRooms                         :: !(IORef (Map ID Room))
  , sSelectedRoom                  :: !(IORef (Maybe ID))
  , sConnectedWalls                :: !(IORef [(Axis, WallRelation, ID, ID)])
  , sMoveTarget                    :: !(IORef MoveTarget)
  , sPickablePoints                :: !(IORef (Map ID Vec3)) -- point ID -> point
  , sSelectedPoints                :: !(IORef [Vec3]) -- points in 3D space (not references)
  }

instance Show TransientState where
  show _ = "TransientState"


data MoveTarget = MoveRoom | MoveWall
  deriving (Eq, Ord, Bounded, Enum, Show, Generic)


enumAll :: (Bounded a, Enum a) => [a]
enumAll = [minBound..maxBound]

cycleEnum :: forall a . (Bounded a, Enum a) => a -> a
cycleEnum e = ( [e..maxBound] ++ [minBound..maxBound] ) !! 1
-- Yay laziness! This is the boring alternative:
-- cycleEnum = toEnum . (\x -> (x+1) `mod` (fromEnum (maxBound :: a) + 1)) . fromEnum


data Save_v1 = Save_v1
  { saveRooms_v1 :: Map ID Room
  } deriving (Eq, Ord, Show, Generic)

data Save = Save
  { saveRooms          :: Map ID Room
  , saveConnectedWalls :: [(Axis, WallRelation, ID, ID)]
  } deriving (Eq, Ord, Show, Generic)

instance ContainsIDs Save where
  getIDs (Save rooms _) = concatMap getIDs (Map.elems rooms)
  bumpIDsBy n s = s
    { saveRooms = Map.mapKeys (+n) . Map.map (bumpIDsBy n) $ saveRooms s
    , saveConnectedWalls = [ (a, wr, i1+n, i2+n) | (a, wr, i1, i2) <- saveConnectedWalls s ]
    }


data Plane = Plane
  { planeID     :: !ID
  , planeEq     :: !PlaneEq
  , planeColor  :: !(Color3 GLfloat)
  , planeBounds :: Vector Vec3
  } deriving (Eq, Ord, Show, Generic)

instance ContainsIDs Plane where
  getIDs p = [planeID p]
  bumpIDsBy n p = p{ planeID = planeID p + n }

-- Convenience
planeNormal :: Plane -> Vec3
planeNormal Plane{ planeEq = PlaneEq n _ } = fromNormal n


data Room_v1 = Room_v1 -- deprecated
  { roomID_v1      :: !ID
  , roomPlanes_v1  :: ![Plane]
  , roomCloud_v1   :: Cloud
  , roomCorners_v1 :: [Vec3] -- TODO newtype this
  } deriving (Eq, Ord, Show, Generic)


data Room_v2 = Room_v2 -- deprecated
  { roomID_v2      :: !ID
  , roomPlanes_v2  :: ![Plane]
  , roomCloud_v2   :: Cloud
  , roomCorners_v2 :: [Vec3] -- TODO newtype this
  , roomProj_v2    :: !Proj4 -- ^ How the room was moved/rotated versus the origin.
  } deriving (Eq, Ord, Show, Generic)


data Room_v3 = Room_v3
  { roomID_v3      :: !ID
  , roomPlanes_v3  :: ![Plane]
  , roomCloud_v3   :: Cloud
  , roomCorners_v3 :: [Vec3] -- TODO newtype this
  , roomProj_v3    :: !Proj4 -- ^ How the room was moved/rotated versus the origin.
  , roomName_v3    :: !String
  } deriving (Eq, Ord, Show, Generic)


data Room = Room
  { roomID      :: !ID
  , roomPlanes  :: ![Plane]
  , roomCloud   :: Cloud
  , roomCorners          :: [(ID, Vec3)] -- TODO newtype this
  , roomSuggestedCorners :: [(ID, Vec3)]
  , roomProj    :: !Proj4 -- ^ How the room was moved/rotated versus the origin.
  , roomName    :: !String
  } deriving (Eq, Ord, Show, Generic)

instance ContainsIDs Room where
  getIDs (Room i planes cloud corners suggs _ _)
    = [i]
      ++ concatMap getIDs planes
      ++ getIDs cloud
      ++ map fst corners
      ++ map fst suggs
  bumpIDsBy n r = r
    { roomID = roomID r + n
    , roomPlanes = map (bumpIDsBy n) (roomPlanes r)
    , roomCloud = bumpIDsBy n (roomCloud r)
    , roomCorners = [ (i+n, c) | (i, c) <- roomCorners r ]
    , roomSuggestedCorners = [ (i+n, c) | (i, c) <- roomSuggestedCorners r ]
    }

data Axis = X | Y | Z
  deriving (Eq, Ord, Show, Generic)


data WallRelation_v1 = Opposite_v1 | Same_v1

data WallRelation
  = Opposite Float -- ^ For walls opposite each other, with distance between them (thickness).
  | Same           -- ^ For walls that are the same, facing in the same direction.
  deriving (Eq, Ord, Show, Generic)


type ID = Word32

-- We pick maxBound as the ID for "there is no object there".
noID :: ID
noID = maxBound

_FIRST_ID :: ID
_FIRST_ID = 1


genID :: State -> IO ID
genID State{ transient = TransientState{ sNextID } } =
  atomicModifyIORef' sNextID (\i -> (i+1 `mod` noID, i))


zipGenIDs :: State -> [a] -> IO [(ID, a)]
zipGenIDs state xs = forM xs $ \c -> do
  cornerId <- genID state
  return (cornerId, c)


class ContainsIDs a where
  getIDs :: a -> [ID]
  bumpIDsBy :: ID -> a -> a


-- |Sets the vertex color
color3 :: GLfloat -> GLfloat -> GLfloat -> IO ()
color3 x y z
  = color $ Color4 x y z 1.0


-- |Sets the vertex position
vertex3 :: GLfloat -> GLfloat -> GLfloat -> IO ()
vertex3 x y z
  = vertex $ Vertex3 x y z


getTimeUs :: IO Int64
getTimeUs = round . (* 1000000.0) <$> getPOSIXTime


withVar :: StateVar a -> a -> IO b -> IO b
withVar var val f = do
  before <- get var
  var $= val
  x <- f
  var $= before
  return x


withDisabled :: [StateVar Capability] -> IO b -> IO b
withDisabled vars f = do
  befores <- mapM get vars
  mapM_ ($= Disabled) vars
  x <- f
  zipWithM_ ($=) vars befores
  return x


upAxis :: Vec3
upAxis = Vec3 0 1 0


-- |Called when stuff needs to be drawn
display :: State -> DisplayCallback
display state@State{..} = do

  ( width, height ) <- get sSize
  rotY              <- get sRotY
  rotUp             <- get sRotUp
  zoom              <- get sZoom
  lookAtPoint       <- get sLookAtPoint

  let buffers = [ ColorBuffer, DepthBuffer ]

  matrixMode $= Projection
  loadIdentity
  perspective 45.0 (fromIntegral width / fromIntegral height) 0.1 500.0

  matrixMode $= Modelview 0
  loadIdentity

  -- Moving around and rotating around the lookAtPoint
  let eye = lookAtPoint &+ zoom *& (vec3Z .* rotMatrixX (toRad (-rotUp))
                                          .* rotMatrixY (toRad (-rotY )))
  lookAt (toGlVertex eye) (toGlVertex lookAtPoint) (toGlVector upAxis)

  -- Do pick rendering (using color picking)
  pickingDisabled <- get sPickingDisabled
  get sPickObjectAt >>= \case
    Just ((x,y), callback) | not pickingDisabled -> do
      i <- colorPicking state (x,y)
      sPickObjectAt $= Nothing
      callback i
    _ -> return ()

  -- Do the normal rendering of all objects
  clear buffers
  preservingMatrix $ drawObjects state
  swapBuffers

  getTimeUs >>= \now -> sLastLoopTime $= Just now


createMenu :: State -> Menu
createMenu state@State{ sWallThickness, sWallMoveStep } = Menu
  [ SubMenu "Wall thickness" $ Menu
      [ MenuEntry (show t ++ " cm") (sWallThickness $= fromCm t)
      | t <- ([0..10] ++ [12,14..20] ++ [25,30..60] :: [Int]) ]
  , SubMenu "Move target" $ Menu
      [ MenuEntry (show mt) (setMoveTarget state mt) | mt <- enumAll :: [MoveTarget] ]
  , SubMenu "Wall move step" $ Menu
      [ MenuEntry (show s ++ " cm") (sWallMoveStep $= fromCm s)
      | s <- [1,10,100] :: [Int] ]
  ]
  where
    fromCm :: Int -> Float
    fromCm cm = fromIntegral cm / 100


idToColor :: ID -> Color4 GLfloat
idToColor i = Color4 (fromIntegral r / 255.0)
                     (fromIntegral g / 255.0)
                     (fromIntegral b / 255.0)
                     (fromIntegral a / 255.0)
  where
    -- From http://stackoverflow.com/questions/664014
    -- hash(i)=i*2654435761 mod 2^32
    col32 = i `rem` noID -- (2654435761 * i) `rem` noID :: Word32 -- noID == maxBound itself is for "no ID" -- TODO find inverse
    r = fromIntegral $ col32 `unsafeShiftR` 24 :: Word8
    g = fromIntegral $ col32 `unsafeShiftR` 16 :: Word8
    b = fromIntegral $ col32 `unsafeShiftR`  8 :: Word8
    a = fromIntegral $ col32                   :: Word8


-- | Render all objects with a distinct color to find out which object
-- is at a given (x,y) coordinate.
-- (x,y) must not be off-screen since `readPixels` is used.
-- Returns `Nothing` if the background is picked.
colorPicking :: State -> (Int, Int) -> IO (Maybe ID)
colorPicking state@State{ transient = TransientState{..}, ..} (x, y) = do
  timeBefore <- getPOSIXTime

  -- Draw background white
  col <- get clearColor
  clearColor $= Color4 1 1 1 1 -- this gives us 0xffffffff == maxBound == noID
  clear [ ColorBuffer, DepthBuffer ] -- we need color and depth for picking
  clearColor $= col

  -- Note: We could probably use glScissor here to restrict drawing to the
  --       one pixel requested.

  i <- withDisabled [ texture Texture2D -- not sure if we should also disable other texture targets
                    , fog
                    , lighting
                    , blend
                    ] $ do

    sPickingMode $= True
    preservingMatrix $ drawObjects state
    sPickingMode $= False
    flush -- so that readPixels reads what we just drew

    ( _, height ) <- get sSize

    -- Get the ID
    i <- alloca $ \(rgbaPtr :: Ptr Word32) -> do
      -- We disable blending for the pick rendering so we can use the
      -- full 32 bits of RGBA for color picking.
      -- readPixels is undefined for off-screen coordinates, so we
      -- require (x,y) to be on-screen.
      readPixels (Position (i2c x) (height-(i2c y)-1)) (Size 1 1) (PixelData RGBA UnsignedByte rgbaPtr)
      -- The color is stored in memory as R-G-B-A bytes, so we have to convert it to big-endian.
      fromBE32 <$> peek rgbaPtr

    -- For debugging we can actually draw the unique colors.
    -- This must happen after readPixels becaus swapBuffers makes the buffer undefined.
    on sDebugPickingDrawVisible swapBuffers

    return i

  on sDebugPickingTiming $ do
    timeAfter <- getPOSIXTime
    putStrLn $ "Picking took " ++ show (timeAfter - timeBefore) ++ " s"

  return $ if i == noID then Nothing else Just i


on :: HasGetter a => a Bool -> IO () -> IO ()
on var f = get var >>= \enabled -> when enabled f


i2c :: Int -> CInt
i2c = fromIntegral

c2i :: CInt -> Int
c2i = fromIntegral


toFloat :: Double -> Float
toFloat = realToFrac

toDouble :: Float -> Double
toDouble = realToFrac


toGlVector :: Fractional a => Vec3 -> Vector3 a
toGlVector (Vec3 a b c) = Vector3 (realToFrac a) (realToFrac b) (realToFrac c)

toGlVertex :: Fractional a => Vec3 -> Vertex3 a
toGlVertex (Vec3 a b c) = Vertex3 (realToFrac a) (realToFrac b) (realToFrac c)


toRad :: Float -> Float
toRad d = d / 180 * pi


-- |Draws the objects to show
drawObjects :: State -> IO ()
drawObjects state@State{ sDisplayPlanes, sDisplayClouds, transient = TransientState{ sPickingMode } } = do
  picking <- get sPickingMode

  -- Objects must only be drawn in picking mode when they are colour picking
  -- aware, that is they query the picking mode and draw themselves only in
  -- colors generated by `idToColor <$> genID` if we are picking.

  when (not picking) $ drawReferenceSystem

  when (not picking) $ drawLookAtPoint state

  when (not picking) $ on sDisplayClouds $ drawPointClouds state

  drawRoomCorners state

  drawPickablePoints state

  when (not picking) $ drawWallConnections state

  on sDisplayPlanes $ drawPlanes state


drawReferenceSystem :: IO ()
drawReferenceSystem = do

  -- displayQuad 1 1 1

  renderPrimitive Lines $ do
    color3 1.0 0.0 0.0
    vertex3 0.0 0.0 0.0
    vertex3 20.0 0.0 0.0

    color3 0.0 1.0 0.0
    vertex3 0.0 0.0 0.0
    vertex3 0.0 20.0 0.0

    color3 0.0 0.0 1.0
    vertex3 0.0 0.0 0.0
    vertex3 0.0 0.0 20.0


drawLookAtPoint :: State -> IO ()
drawLookAtPoint State{ sLookAtPoint } = do

  Vec3 x' y' z' <- get sLookAtPoint
  let (x, y, z) = (realToFrac x', realToFrac y', realToFrac z' :: GLfloat)

  renderPrimitive Lines $ do
    color3 0.4 0.4 0.4
    vertex3 (x - 0.5) y z
    vertex3 (x + 0.5) y z
    vertex3 x         y (z - 0.5)
    vertex3 x         y (z + 0.5)


drawPointClouds :: State -> IO ()
drawPointClouds State{ sPointSize, transient = TransientState{ sAllocatedClouds } } = do

  allocatedClouds <- get sAllocatedClouds

  (pointSize $=) . realToFrac =<< get sPointSize

  -- Render all clouds
  forM_ (Map.elems allocatedClouds) $ \(Cloud{ cloudColor = colType, cloudPoints }, bufObj, m'colorObj) -> do

    clientState VertexArray $= Enabled

    case (colType, m'colorObj) of
      (OneColor col, Nothing) -> color col
      (ManyColors _, Just colorObj) -> do
        clientState ColorArray $= Enabled
        bindBuffer ArrayBuffer $= Just colorObj
        arrayPointer ColorArray $= VertexArrayDescriptor 3 Float 0 nullPtr
      _ -> error $ "bad combination of CloudColor and buffer: " ++ show m'colorObj

    bindBuffer ArrayBuffer $= Just bufObj
    arrayPointer VertexArray $= VertexArrayDescriptor 3 Float 0 nullPtr

    drawArrays Points 0 (i2c $ V.length cloudPoints)
    bindBuffer ArrayBuffer $= Nothing

    clientState VertexArray $= Disabled
    -- If we don't disable this, a subsequent draw with only 1 color using `color` will segfault
    clientState ColorArray $= Disabled


drawRoomCorners :: State -> IO ()
drawRoomCorners State{ transient = TransientState{ sRooms, sPickingMode }, ..} = do
  rooms <- Map.elems <$> get sRooms
  picking <- get sPickingMode
  underCursor <- get sUnderCursor

  withVar pointSize 8.0 $ do
    renderPrimitive Points $ do

      -- Room corner suggestions if we don't have enough corners
      forM_ rooms $ \Room{ roomSuggestedCorners, roomCorners } -> do
        when (length roomCorners /= 8) $ do

          forM_ roomSuggestedCorners $ \(i, c) -> do
            color $ if
              | picking               -> idToColor i
              | underCursor == Just i -> Color4 0 1 0 1
              | otherwise             -> Color4 0 0 1 1 -- TODO check why transparency doesn't work
            vertexVec3 c

      -- Room corners
      forM_ rooms $ \Room{ roomCorners } -> do
        if (length roomCorners /= 8)
          then do
            color red
            mapM_ (vertexVec3 . snd) roomCorners
          else do
            let [a,b,c,d,e,f,g,h] = map snd roomCorners
            color3 0.3 0.6 0.3 >> vertexVec3 a
            color3 0 0 1 >> vertexVec3 b
            color3 0 1 0 >> vertexVec3 c
            color3 0 1 1 >> vertexVec3 d
            color3 1 0 0 >> vertexVec3 e
            color3 1 0 1 >> vertexVec3 f
            color3 1 1 0 >> vertexVec3 g
            color3 1 1 1 >> vertexVec3 h


drawPickablePoints :: State -> IO ()
drawPickablePoints State{ transient = TransientState{ sPickablePoints, sPickingMode }, ..} = do

  pickablePoints <- get sPickablePoints
  picking <- get sPickingMode
  underCursor <- get sUnderCursor

  withVar pointSize 8.0 $ do
    renderPrimitive Points $ do

      forM_ (Map.toList pickablePoints) $ \(i, c) -> do
        color $ if
          | picking               -> idToColor i
          | underCursor == Just i -> Color4 0 1 0 1
          | otherwise             -> Color4 0 0 1 1 -- TODO check why transparency doesn't work
        vertexVec3 c


drawWallConnections :: State -> IO ()
drawWallConnections  State{ transient = TransientState{ sConnectedWalls, sRooms } } = do
  conns <- get sConnectedWalls
  allRoomPlanes <- concatMap roomPlanes . Map.elems <$> get sRooms

  forM_ conns $ \(axis, relation, pid1, pid2) -> do

    -- Find the two planes with these plane IDs
    case ( find ((== pid1) . planeID) allRoomPlanes
         , find ((== pid2) . planeID) allRoomPlanes ) of
      (Just p1, Just p2) -> do

        case axis of
          X -> color3 1.0 0.0 0.0
          Y -> color3 0.0 1.0 0.0
          Z -> color3 0.0 0.0 1.0

        let withStyle = case relation of
              Opposite _ -> id
              Same       -> withVar lineStipple (Just (1, 0x03ff))

        withStyle $ do
          renderPrimitive Lines $ do
            vertexVec3 (planeMean p1)
            vertexVec3 (planeMean p2)

      _ -> putStrLn $ "Room planes not found: " ++ show (pid1, pid2)


drawPlanes :: State -> IO ()
drawPlanes State{ transient = TransientState{ sPlanes, sRooms, sPickingMode }, ..} = do

  planePols <- Map.elems <$> get sPlanes
  wallPlanes <- concatMap roomPlanes . Map.elems <$> get sRooms

  debugProject <- get sDebugProjectPlanePointsToEq
  let roomPols
        -- This reveals bugs in the plane projection code: It uses the
        -- actual plane equation for drawing the points.
        | debugProject = [ p{ planeBounds = V.map (projectToPlane eq) points }
                         | p@(Plane _ eq _ points) <- wallPlanes ]
        | otherwise = wallPlanes

  let pols = planePols ++ roomPols

  picking <- get sPickingMode
  underCursor <- get sUnderCursor

  let drawPolys = do
        forM_ pols $ \(Plane i _ (Color3 r g b) points) -> do

          renderPrimitive Polygon $ do
            color $ if
              | picking               -> idToColor i
              | underCursor == Just i -> Color4 r g b 0.8
              | otherwise             -> Color4 r g b 0.5
            V.mapM_ vertexVec3 points

  -- Get "real" transparency for overlapping polygons by drawing them last,
  -- and disabling the depth test for their drawing
  -- (transparency must be 0.5 for all polygons for this technique).
  -- From http://stackoverflow.com/questions/4127242
  -- If we are picking, of course we don't want any color blending, so we
  -- keep the depth test on.
  if picking then                          drawPolys
             else withDisabled [depthMask] drawPolys


processCloudQueue :: State -> IO ()
processCloudQueue State{ transient = TransientState{ sAllocatedClouds }, queuedClouds } = do

  -- Get out queued clouds, set queued clouds to []
  queued <- atomicModifyIORef' queuedClouds (\cls -> (Map.empty, Map.elems cls))

  -- Go over the queue contents
  forM_ queued $ \cloud@Cloud{ cloudID = i, cloudPoints, cloudColor } -> do

    -- If the ID is already allocated, deallocate the corresponding buffers
    allocatedClouds <- get sAllocatedClouds
    for_ (Map.lookup i allocatedClouds) $ \(_, bufObj, m'colorObj) -> do
      deleteObjectName bufObj
      for_ m'colorObj deleteObjectName
      sAllocatedClouds $~ Map.delete i

    -- Allocate buffer object containing all these points
    bufObj <- fromVector ArrayBuffer cloudPoints

    -- Allocate color buffer if we don't use only 1 color
    m'colorObj <- case cloudColor of
      OneColor _             -> return Nothing
      ManyColors pointColors -> Just <$> fromVector ArrayBuffer pointColors

    sAllocatedClouds $~ Map.insert i (cloud, bufObj, m'colorObj)


atomicModifyIORef_ :: IORef a -> (a -> a) -> IO ()
atomicModifyIORef_ ref f = atomicModifyIORef' ref (\x -> (f x, ()))


addPointCloud :: State -> Cloud -> IO ()
addPointCloud State{ transient = TransientState{..}, ..} cloud@Cloud{ cloudID = i } = do
  -- Make sure a cloud with that id doesn't already exist
  queued <- get queuedClouds
  allocated <- get sAllocatedClouds
  when (i `Map.member` queued || i `Map.member` allocated) $
    error $ "Cloud with id " ++ show i ++ " already exists"

  atomicModifyIORef_ queuedClouds (Map.insert i cloud)


updatePointCloud :: State -> Cloud -> IO ()
updatePointCloud State{ queuedClouds } cloud@Cloud{ cloudID = i } = do
  atomicModifyIORef_ queuedClouds (Map.insert i cloud)


initializeObjects :: State -> IO ()
initializeObjects _state = do
  return ()


-- |Displays a quad
displayQuad :: GLfloat -> GLfloat -> GLfloat -> IO ()
displayQuad w h d = preservingMatrix $ do
  scale w h d

  renderPrimitive Quads $ do
    color3 1.0 0.0 0.0
    vertex3 (-1.0) ( 1.0) ( 1.0)
    vertex3 (-1.0) (-1.0) ( 1.0)
    vertex3 ( 1.0) (-1.0) ( 1.0)
    vertex3 ( 1.0) ( 1.0) ( 1.0)

    color3 1.0 0.0 0.0
    vertex3 (-1.0) (-1.0) (-1.0)
    vertex3 (-1.0) ( 1.0) (-1.0)
    vertex3 ( 1.0) ( 1.0) (-1.0)
    vertex3 ( 1.0) (-1.0) (-1.0)

    color3 0.0 1.0 0.0
    vertex3 ( 1.0) (-1.0) ( 1.0)
    vertex3 ( 1.0) (-1.0) (-1.0)
    vertex3 ( 1.0) ( 1.0) (-1.0)
    vertex3 ( 1.0) ( 1.0) ( 1.0)

    color3 0.0 1.0 0.0
    vertex3 (-1.0) (-1.0) (-1.0)
    vertex3 (-1.0) (-1.0) ( 1.0)
    vertex3 (-1.0) ( 1.0) ( 1.0)
    vertex3 (-1.0) ( 1.0) (-1.0)

    color3 0.0 0.0 1.0
    vertex3 (-1.0) (-1.0) ( 1.0)
    vertex3 (-1.0) (-1.0) (-1.0)
    vertex3 ( 1.0) (-1.0) (-1.0)
    vertex3 ( 1.0) (-1.0) ( 1.0)

    color3 0.0 0.0 1.0
    vertex3 (-1.0) ( 1.0) (-1.0)
    vertex3 (-1.0) ( 1.0) ( 1.0)
    vertex3 ( 1.0) ( 1.0) ( 1.0)
    vertex3 ( 1.0) ( 1.0) (-1.0)

-- |Called when the sSize of the viewport changes
reshape :: State -> ReshapeCallback
reshape State{..} (Size width height) = do
  sSize $= ( width, height )
  viewport $= (Position 0 0, Size width height)
  postRedisplay Nothing


-- |Animation
idle :: State -> IdleCallback
idle state@State{..} = do

  -- Allocate BufferObjects for all queued clouds
  processCloudQueue state

  get sLastLoopTime >>= \case
    Nothing -> return ()
    Just lastLoopTime -> do
      now <- getTimeUs
      fps <- get sFps
      let sleepTime = max 0 $ 1000000 `quot` fps - fromIntegral (now - lastLoopTime)
      threadDelay sleepTime

  postRedisplay Nothing
  getTimeUs >>= \now -> sLastLoopTime $= Just now

  -- If a restart is requested, stop the main loop.
  -- The code after the main loop will do the actual restart.
  shallRestart <- get sRestartRequested
  when shallRestart leaveMainLoop


-- | Called when the OpenGL window is closed.
close :: State -> CloseCallback
close State{..} = do
  putStrLn "window closed"


-- | Mouse motion (with buttons pressed)
motion :: State -> Position -> IO ()
motion State{..} (Position posx posy) = do

  ( oldx, oldy ) <- get sMouse
  let diffH = fromIntegral $ posx - oldx
      diffV = fromIntegral $ posy - oldy

  sMouse $= ( posx, posy )

  get sDragMode >>= \case
    Just Rotate -> do
      let clamp (l,u) x = min u (max l x)
      sRotY  $~! (+ diffH)
      sRotUp $~! (clamp (-89.999, 89.999) . (+ diffV)) -- full 90 gives non-smooth rotation behaviour
    Just Translate -> do
      zoom  <- get sZoom
      rotY  <- get sRotY
      rotUp <- get sRotUp
      -- Where left/right/up/down is depends on the rotation around the
      -- up axis (rotY), and how much to move depends on the zoom.
      -- rotUp allows us to go below the ground plane; since we always want to
      -- "drag the ground plane around", we have to invert the Z component then.
      let movVec = Vec3 (-diffH) 0 (-diffV * signum rotUp)
      sLookAtPoint $~! (&+ (0.0025 * zoom) *& (movVec .* rotMatrixY (toRad $ -rotY)))
    _ -> return ()


-- | Mouse motion (without buttons pressed)
passiveMotion :: State -> Position -> IO ()
passiveMotion state@State{..} (Position posx posy) = do

  sPickObjectAt $= Just ((c2i posx, c2i posy), objectHover state)



changeFps :: State -> (Int -> Int) -> IO ()
changeFps State{ sFps } f = do
  sFps $~ f
  putStrLn . ("FPS: " ++) . show =<< get sFps


-- |Button input
input :: State -> Key -> KeyState -> Modifiers -> Position -> IO ()
input state@State{..} (MouseButton LeftButton) Down _ (Position x y) = do
  sPickObjectAt $= Just ((c2i x, c2i y), objectClick state)
  sMouse $= ( x, y )
  sDragMode $= Just Translate
input State{..} (MouseButton LeftButton) Up _ (Position x y) = do
  sMouse $= ( x, y )
  sDragMode $= Nothing
input State{..} (MouseButton RightButton) Down _ (Position x y) = do
  sMouse $= ( x, y )
  sDragMode $= Just Rotate
input State{..} (MouseButton RightButton) Up _ (Position x y) = do
  sMouse $= ( x, y )
  sDragMode $= Nothing
input state (MouseButton WheelDown) Down _ pos
  = wheel state 0 120 pos
input state (MouseButton WheelUp) Down _ pos
  = wheel state 0 (-120) pos
input state (Char '[') Down _ _ = changeFps state pred
input state (Char ']') Down _ _ = changeFps state succ
input state (Char '\r') Down _ _ = addDevicePointCloud state
input state (Char 'c') Down _ _ = addCornerPoint state
input state (Char '\DEL') Down _ _ = deleteSelectedPlane state
input state (Char 'g') Down _ _ = suggestPoints state
input state (Char 'f') Down _ _ = fitCuboidToSelectedRoom state
input state (Char 'S') Down _ _ = makeSelectedRoomPointsPickable state
input state (Char 'P') Down _ _ = planeFromSelectedPoints state
input state (Char 'r') Down _ _ = rotateSelectedPlanes state
input state (Char 's') Down _ _ = save state
input state (Char 'l') Down _ _ = load state
input state (Char '/') Down _ _ = devSetup state
input state (Char 'd') Down _ _ = sDisplayPlanes state $~ not
input state (Char 'p') Down _ _ = sDisplayClouds state $~ not
input state (Char '+') Down _ _ = sPointSize state $~ (+ 1.0)
input state (Char '-') Down _ _ = sPointSize state $~ (abs . subtract 1.0)
input state (Char '\b') Down _ _ = clearRooms state
input state (Char ' ') Down _ _ = clearSelections state
input state (Char '#') Down _ _ = swapRoomPositions state
input state (Char 'a') Down _ _ = autoAlignAndRotate state
input state (Char '1') Down _ _ = houseSetup groundFloorRooms state
input state (Char '2') Down _ _ = loadFrom state "u51-ground-fitted-rotated-moved.safecopy.bin"
input state (Char '3') Down _ _ = loadFrom state "u51-ground-fitted-corrected-ordered-connected.safecopy.bin"
input state (Char '4') Down _ _ = loadFrom state "u51-house-done.safecopy.bin"
input state (Char 'w') Down _ _ = do d <- get (sWallThickness state)
                                     connectWalls state (Opposite d)
input state (Char 'W') Down _ _ = connectWalls state Same
input state (Char '\^W') Down _ _ = disconnectWalls state
input state (Char 'o') Down _ _ = optimizeRoomPositions state
input state (Char 'e') Down _ _ = exportRoomProjection state
input state (Char 'm') Down _ _ = switchMoveTarget state
input state (Char 'D') Down _ _ = duplicateSelectedPlane state
input state (SpecialKey KeyUp      ) Down _ _ = moveDirection state (Vec3   0    0 (-1))
input state (SpecialKey KeyDown    ) Down _ _ = moveDirection state (Vec3   0    0   1 )
input state (SpecialKey KeyLeft    ) Down _ _ = moveDirection state (Vec3 (-1)   0   0 )
input state (SpecialKey KeyRight   ) Down _ _ = moveDirection state (Vec3   1    0   0 )
input state (SpecialKey KeyPageUp  ) Down _ _ = moveDirection state (Vec3   0    1   0 )
input state (SpecialKey KeyPageDown) Down _ _ = moveDirection state (Vec3   0  (-1)  0 )
input _state key Down _ _ = putStrLn $ "Unhandled key " ++ show key
input _state _ _ _ _ = return ()


-- | Called when picking notices a hover over an object
objectHover :: State -> Maybe ID -> IO ()
objectHover State{..} m'i = do
  sUnderCursor $= m'i


-- | Called when picking notices a click on an object
objectClick :: State -> Maybe ID -> IO ()
objectClick _      Nothing  = putStrLn $ "Clicked: Background"
objectClick state@State{ transient = TransientState{..}, ..} (Just i) = do
  putStrLn $ "Clicked: " ++ show i

  rooms <- Map.elems <$> get sRooms

  case findRoomContainingPlane rooms i of
    Nothing -> sSelectedRoom $= Nothing
    Just Room{ roomID, roomName } -> do
      putStrLn $ "Room: " ++ show roomID ++ " (" ++ roomName ++ ")"
      sSelectedRoom $= Just roomID

  getAnyPlaneID state i >>= \case
    Nothing -> return ()
    Just p -> do
      putStrLn $ "Plane: " ++ show i
      putStrLn $ "PlaneEq: " ++ show (planeEq p)
      selected <- get sSelectedPlanes
      when (i `notElem` selected) $ do
        sSelectedPlanes $~ (i:)

  -- Suggested corner click
  for_ (findRoomContainingSuggestedCorner rooms i) $ \r -> do
    acceptCornerSuggestion state r i

  -- Pickable point click
  Map.lookup i <$> get sPickablePoints >>= \case
    Nothing -> return ()
    Just vec -> atomicModifyIORef_ sSelectedPoints (vec:)


-- |Mouse wheel movement (sZoom)
wheel :: State -> WheelNumber -> WheelDirection -> Position -> IO ()
wheel State{..} _num dir _pos
  | dir > 0   = get sZoom >>= (\x -> sZoom $= clamp (x * 1.2))
  | otherwise = get sZoom >>= (\x -> sZoom $= clamp (x / 1.2))
  where
    clamp x = 0.5 `max` (300.0 `min` x)


-- | Creates the default state
createState :: IO State
createState = do
  sMouse            <- newIORef ( 0, 0 )
  sDragMode         <- newIORef Nothing
  sSize             <- newIORef ( 0, 1 )
  sRotUp            <- newIORef 30
  sRotY             <- newIORef (- 30)
  sZoom             <- newIORef 20.0
  sLookAtPoint      <- newIORef zero
  queuedClouds      <- newIORef Map.empty
  sFps              <- newIORef 30
  sLastLoopTime     <- newIORef Nothing
  sRestartRequested <- newIORef False
  sGlInitialized    <- newIORef False
  sRestartFunction  <- newIORef (error "restartFunction called before set")
  sPickingDisabled  <- newIORef False
  sPickObjectAt     <- newIORef Nothing
  sUnderCursor      <- newIORef Nothing
  sDebugPickingDrawVisible <- newIORef False
  sDebugPickingTiming      <- newIORef False
  sWallThickness    <- newIORef 0.1
  sDisplayPlanes    <- newIORef True
  sDisplayClouds    <- newIORef True
  sPointSize        <- newIORef 2.0
  sSuggestionCutoffFactor <- newIORef 1.2
  sWallMoveStep     <- newIORef 0.01
  sDebugProjectPlanePointsToEq <- newIORef True -- It is a good idea to keep this on, always
  transient         <- createTransientState

  return State{..} -- RecordWildCards for initialisation convenience


createTransientState :: IO TransientState
createTransientState = do
  sNextID <- newIORef _FIRST_ID
  sPickingMode <- newIORef False
  sAllocatedClouds <- newIORef Map.empty
  sPlanes <- newIORef Map.empty
  sSelectedPlanes <- newIORef []
  sRooms <- newIORef Map.empty
  sSelectedRoom <- newIORef Nothing
  sConnectedWalls <- newIORef []
  sMoveTarget <- newIORef MoveRoom
  sPickablePoints <- newIORef Map.empty
  sSelectedPoints <- newIORef []
  return TransientState{..}


-- |Main
main :: IO ()
main = do
  state <- createState
  mainState state


-- | Run `main` on a state.
mainState :: State -> IO ()
mainState state@State{..} = do

  _ <- forkSelfRestartExePollWithAction 1.0 $ do
    putStrLn "executable changed, restarting"
    threadDelay 1500000

  -- Initialize OpenGL
  _ <- getArgsAndInitialize

  -- Enable double buffering
  initialDisplayMode $= [RGBAMode, WithDepthBuffer, DoubleBuffered]

  -- Create window
  _ <- createWindow "3D cloud viewer"
  sGlInitialized $= True

  clearColor  $= Color4 0 0 0 1
  shadeModel  $= Smooth
  depthMask   $= Enabled
  depthFunc   $= Just Lequal
  blend       $= Enabled
  blendFunc   $= (SrcAlpha, OneMinusSrcAlpha)
  lineWidth   $= 3.0
  lineSmooth  $= Enabled

  -- Callbacks
  displayCallback       $= display state
  reshapeCallback       $= Just (reshape state)
  idleCallback          $= Just (idle state)
  mouseWheelCallback    $= Just (wheel state)
  motionCallback        $= Just (motion state)
  passiveMotionCallback $= Just (passiveMotion state)
  keyboardMouseCallback $= Just (input state)
  closeCallback         $= Just (close state)

  -- Menu
  attachMenu MiddleButton (createMenu state)

  initializeObjects state

  -- Let's get started
  actionOnWindowClose $= ContinueExecution
  mainLoop -- blocks while windows are open
  exit
  sGlInitialized $= False
  putStrLn "Exited OpenGL loop"

  -- Restart if requested
  on sRestartRequested $ do
    putStrLn "restarting"
    sRestartRequested $= False -- Note: This is for the new state;
                               -- works because this is not transient.
    -- We can't just call `mainState state` here since that would (tail) call
    -- the original function instead of the freshly loaded one. That's why the
    -- function is put into the IORef to be updated by `restart`.
    f <- get sRestartFunction
    f


-- | For debugging / ghci only.
getState :: IO State
getState = lookupStore _STORE_STATE >>= \case
  Just store -> readStore store
  Nothing    -> error "state not available; call restart first"


-- | For debugging / ghci only.
run :: (State -> IO a) -> IO a
run f = getState >>= f


-- Store IDs for Foreign.Store
_STORE_STATE, _STORE_STATE_TYPE_STRING :: Word32
_STORE_STATE = 0
_STORE_STATE_TYPE_STRING = 1


-- For restarting the program in GHCI while keeping the `State` intact.
restart :: (State -> IO ()) -> IO ()
restart mainStateFun = do
  -- Note: We have to pass in the `mainState` function from the global
  --       ghci scope as `mainStateFun` instead of just calling the
  --       `mainState` already visible from here - that would call the
  --       old `mainState`, not the freshly loaded one.
  lookupStore _STORE_STATE >>= \case
    Nothing -> do
      putStrLn "restart: starting for first time"
      state <- createState

      -- Store the state
      newStore state >>= \(Store i) -> when (i /= _STORE_STATE) $
        error "state store has bad store id"

      -- Store the type representation string of the state.
      -- This way we can detect whether the state changed when doing hot code
      -- reloading in in-place restarts in ghci.
      -- Using Generics, this really works on the *structure* of the `State`
      -- type, so hot code reloading even works when the name of a field in
      -- the `State` record changes!
      newStore (show $ from state) >>= \(Store i) -> when (i /= _STORE_STATE_TYPE_STRING) $
        error "state type representation string store has bad store id"

      void $ forkIO (mainStateFun state)

    Just store -> do
      putStrLn "restart: having existing store"

      -- Check state type. If it changed, abort reloading
      -- (otherwise we get a segfault since the memory layout changed).
      lookupStore _STORE_STATE_TYPE_STRING >>= \case
        Nothing -> error "restart: State type representation string missing"
        Just stateTypeStore -> do
          stateTypeString <- readStore stateTypeStore
          tmpState <- createState -- something we can compare with
          -- TODO This might fail to reload even if the types are the same
          --      if we have e.g. an Either in our state:
          --      Flipping it from Left to Right will change the type string.
          --      For now this is fine since our State only has IORefs.
          when (stateTypeString /= show (from tmpState)) $
            -- `error` is fine here since this can only be called from
            -- ghci anyway, and `error` won't terminate ghci.
            error "cannot restart in-place: the State type changed"

      -- All clear, state is safe to load.

      oldState <- readStore store

      -- Only store an empty transient state so that we can't access
      -- things that cannot survive a reload (like GPU buffers).
      emptyTransientState <- createTransientState
      let newState = oldState{ transient = emptyTransientState }

      deleteStore store
      _ <- newStore newState

      -- If OpenGL is (still or already) initialized, just ask it to
      -- shut down in the next `idle` loop.
      get (sGlInitialized oldState) >>= \case
        True  -> do -- Ask the GL loop running on the old state to
                    -- restart for us.
                    sRestartRequested oldState $= True
                    sRestartFunction oldState $= mainStateFun newState
                    -- TODO We should also deallocate all BufferObjects.
        False -> void $ forkIO $ mainStateFun newState


getRandomColor :: IO (Color3 GLfloat)
getRandomColor = Color3 <$> randomRIO (0,1)
                        <*> randomRIO (0,1)
                        <*> randomRIO (0,1)


-- Add some random points as one point cloud
addRandomPoints :: State -> IO ()
addRandomPoints state = do
  x <- randomRIO (0, 10)
  y <- randomRIO (0, 10)
  z <- randomRIO (0, 10)
  i <- genID state
  let points = map mkVec3 [(x+1,y+2,z+3),(x+4,y+5,z+6)]
      colour = Color3 (realToFrac $ x/10) (realToFrac $ y/10) (realToFrac $ z/10)
  addPointCloud state $ Cloud i (OneColor colour) (V.fromList points)

-- addPointCloud globalState Cloud{ cloudColor = Color3 0 0 1, cloudPoints = V.fromList [ Vec3 x y z | x <- [1..4], y <- [1..4], let z = 3 ] }

addDevicePointCloud :: State -> IO ()
addDevicePointCloud state = do
  putStrLn "Depth snapshot: start"
  s <- takeDepthSnapshot
  putStrLn "Depth snapshot: done"

  case s of
    Left err -> hPutStrLn stderr $ "WARNING: " ++ err
    Right (depthVec, (width, _height)) -> do

      r <- randomRIO (0, 1)
      g <- randomRIO (0, 1)
      b <- randomRIO (0, 1)

      let points =   V.map scalePoints
                   . V.filter (\(Vec3 _ _ d) -> d /= 0) -- remove 0 depth points
                   . V.imap (\i depth ->                -- convert x/y/d to floats
                       let (y, x) = i `quotRem` width
                        in Vec3 (fromIntegral x) (fromIntegral y) (fromIntegral depth)
                     )
                   $ depthVec

      i <- genID state
      addPointCloud state $ Cloud i (OneColor $ Color3 r g b) points

  where
    -- Scale the points from the camera so that they appear nicely in 3D space.
    -- TODO remove X/Y scaling by changing the camera in the viewer
    -- TODO Use camera intrinsics + error correction function
    scalePoints (Vec3 x y d) = Vec3 (x / 10.0)
                                    (y / 10.0)
                                    (d / 20.0 - 30.0)


vertexVec3 :: Vec3 -> IO ()
vertexVec3 (Vec3 x y z) = vertex (Vertex3 (realToFrac x) (realToFrac y) (realToFrac z) :: Vertex3 GLfloat)


loadPCDFileXyzFloat :: FilePath -> IO (Vector Vec3)
loadPCDFileXyzFloat file = V.map v3toVec3 <$> PCD.loadXyz file
  where
    v3toVec3 (V3 a b c) = Vec3 a b c

loadPCDFileXyzRgbNormalFloat :: FilePath -> IO (Vector Vec3, Vector Vec3)
loadPCDFileXyzRgbNormalFloat file = do
  ps <- PCD.loadXyzRgbNormal file
  return (V.map (v3toVec3 . PCD.xyz) ps, V.map (rgbToFloats . PCD.rgb) ps)
  where
    rgbToFloats (V3 r g b) = Vec3 (fromIntegral r / 255.0) (fromIntegral g / 255.0) (fromIntegral b / 255.0)
    v3toVec3 (V3 a b c) = Vec3 a b c


cloudFromFile :: State -> FilePath -> IO Cloud
cloudFromFile state file = do
  -- TODO this switching is nasty, pcl-loader needs to be improved
  i <- genID state
  p1 <- loadPCDFileXyzFloat file
  if not (V.null p1)
    then return $ Cloud i (OneColor $ Color3 1 0 0) p1
    else do
      (p2, colors) <- loadPCDFileXyzRgbNormalFloat file
      if not (V.null p2)
        then return $ Cloud i (ManyColors colors) p2
        else error $ "File " ++ file ++ " contains no points!" -- TODO This is not clean


loadPCDFile :: State -> FilePath -> IO ()
loadPCDFile state file = do
  addPointCloud state =<< cloudFromFile state file



-- | Plane equation: ax + by + cz = d, or: n*xyz = d
-- (Hessian normal form). It matters that the d is on the
-- right hand side since we care about plane normal direction.
data PlaneEq = PlaneEq !Normal3 !Float -- parameters: a b c d
  deriving (Eq, Ord, Show, Generic)

mkPlaneEq :: Vec3 -> Float -> PlaneEq
mkPlaneEq abc d = PlaneEq (mkNormal abc) (d / norm abc)

mkPlaneEqABCD :: Float -> Float -> Float -> Float -> PlaneEq
mkPlaneEqABCD a b c d = mkPlaneEq (Vec3 a b c) d


flipPlaneEq :: PlaneEq -> PlaneEq
flipPlaneEq (PlaneEq n d) = PlaneEq (flipNormal n) (-d)


signedDistanceToPlaneEq :: PlaneEq -> Vec3 -> Float
signedDistanceToPlaneEq (PlaneEq n d) p = fromNormal n `dotprod` p - d


projectToPlane :: PlaneEq -> Vec3 -> Vec3
projectToPlane eq@(PlaneEq n _) p = p &- (signedDistanceToPlaneEq eq p *& fromNormal n)


planeEqsFromFile :: FilePath -> IO [PlaneEq]
planeEqsFromFile file = do
  let float = realToFrac <$> double
      floatS = float <* skipSpace
      -- PCL exports plane in the form `ax + by + cz + d = 0`,
      -- we need `ax + by + cz = d`.
      planesParser = (mkPlaneEqABCD <$> floatS <*> floatS <*> floatS <*> (negate <$> float))
                     `sepBy1'` endOfLine
  parseOnly planesParser <$> BS.readFile file >>= \case
    Left err -> error $ "Could not load planes: " ++ show err
    Right planes -> return planes


planesFromDir :: State -> FilePath -> IO [Plane]
planesFromDir state dir = do
  eqs <- planeEqsFromFile (dir </> "planes.txt")
  forM (zip [0..] eqs) $ \(x :: Int, eq) -> do
    let name = "cloud_plane_hull" ++ show x ++ ".pcd"
        file = dir </> name
    putStrLn $ "Loading " ++ file

    points <- loadPCDFileXyzFloat file
    col <- getRandomColor
    i <- genID state

    return $ Plane i eq col points


loadPlanes :: State -> FilePath -> IO ()
loadPlanes state dir = do
  planes <- planesFromDir state dir
  forM_ planes (addPlane state)


planeCorner :: PlaneEq -> PlaneEq -> PlaneEq -> Maybe Vec3
planeCorner (PlaneEq n1 d1)
            (PlaneEq n2 d2)
            (PlaneEq n3 d3) = res
  where
    -- TODO Figure out how to detect when the system isn't solvable (parallel planes)
    Vec3 a1 b1 c1 = fromNormal n1
    Vec3 a2 b2 c2 = fromNormal n2
    Vec3 a3 b3 c3 = fromNormal n3
    f = realToFrac :: Double -> Float
    d = realToFrac :: Float -> Double
    lhs = (3><3)[ d a1, d b1, d c1
                , d a2, d b2, d c2
                , d a3, d b3, d c3 ]
    rhs = (3><1)[ d d1, d d2, d d3 ]
    res = do -- Maybe monad
      [x,y,z] <- HmatrixVec.toList . Matrix.flatten <$> safeLinearSolve lhs rhs
      return $ Vec3 (f x) (f y) (f z)


-- | Finds the best fitting plane (total least squares).
--
-- Implemented as the normal vector being the smallest eigenvector in PCA.
fitPlane :: Vector Vec3 -> PlaneEq
fitPlane points
  | n < 3     = error $ "fitPlane: " ++ show n ++ " points given, need at least 3"
  | otherwise = PlaneEq (mkNormal $ Vec3 nx ny nz) d
  where
    meanSubtracted = V.toList $ V.map (toDoubleVec . (&- m)) points
    n = V.length points
    pointMat = Matrix.trans $ (n >< 3) $ concat
                 [ [x,y,z] | Vect.Double.Vec3 x y z <- meanSubtracted ]
    (_, eigVecs) = Matrix.eigSH (pointMat Matrix.<> Matrix.trans pointMat)
    [ [_, _, nx],
      [_, _, ny],
      [_, _, nz] ] = map (map toFloat) $ Matrix.toLists eigVecs
    d = signedDistanceToPlaneEq (PlaneEq (mkNormal $ Vec3 nx ny nz) 0) m
    m = pointMean points


red :: Color3 GLfloat
red = Color3 1 0 0



getAnyPlaneID :: State -> ID -> IO (Maybe Plane)
getAnyPlaneID State{ transient = TransientState{ sRooms, sPlanes } } i = do
  allPlanes <- do
    planes <- Map.elems <$> get sPlanes
    rooms <- Map.elems <$> get sRooms
    return (planes ++ concatMap roomPlanes rooms)
  return $ find (\Plane{ planeID } -> planeID == i) allPlanes


deleteSelectedPlane :: State -> IO ()
deleteSelectedPlane state@State{ transient = TransientState{..}, ..} = do
  get sSelectedPlanes >>= \case
      [pid]-> do
        -- First check if p is part of a room.
        rooms <- Map.elems <$> get sRooms
        case findRoomContainingPlane rooms pid of
          Just r -> do
            updateRoom state r{ roomPlanes = [ p' | p' <- roomPlanes r, planeID p' /= pid ] }
          _ -> do
            sPlanes $~ Map.delete pid

      ps -> putStrLn $ show (length ps) ++ " planes selected, need 3"

  sSelectedPlanes $= []


addCornerToRoom :: State -> (ID, Vec3) -> Room -> IO ()
addCornerToRoom state sugg r = do
  updateRoom state r{ roomCorners = sugg : roomCorners r
                    , roomSuggestedCorners = roomSuggestedCorners r \\ [sugg]
                    }


addCornerPoint :: State -> IO ()
addCornerPoint state@State{ transient = TransientState{..}, ..} = do
  get sSelectedPlanes >>= \case
    pids@[_,_,_] -> do
      [Just p1, Just p2, Just p3] <- mapM (getAnyPlaneID state) pids

      case planeCorner (planeEq p1) (planeEq p2) (planeEq p3) of
        Nothing -> putStrLn "Planes do not intersect!"
        Just corner -> do

          -- First check if p1 is part of a room.
          rooms <- Map.elems <$> get sRooms
          case [ r | pid <- pids
                   , Just r <- [findRoomContainingPlane rooms pid] ] of
            [r@Room{ roomID = i },r2,r3] | roomID r2 == i && roomID r3 == i -> do
              case roomCorners r of
                corners | length corners < 8 -> do
                  putStrLn $ "Merging planes of room to corner " ++ show corner
                  cornerId <- genID state
                  addCornerToRoom state (cornerId, corner) r
                _ -> putStrLn $ "Room " ++ show i ++ " already has 8 corners"
            _ -> do
              putStrLn $ "Merged planes to corner " ++ show corner
              i <- genID state
              addPointCloud state $ Cloud i (OneColor red) (V.fromList [corner])

    ps -> putStrLn $ show (length ps) ++ " planes selected, need 3"

  sSelectedPlanes $= []


suggestPoints :: State -> IO ()
suggestPoints state@State{..} = withSelectedRoom state $ \r -> do
  cutoffFactor <- get sSuggestionCutoffFactor
  let planes = roomPlanes r
      allCorners = [ planeCorner (planeEq p) (planeEq q) (planeEq s) | p <- planes, q <- planes, s <- planes, p < q, q < s ]
      maxMeanDistance = V.maximum . V.map (distance (roomMean r)) $ cloudPoints (roomCloud r)
      cutoff = cutoffFactor * maxMeanDistance

  suggestedCorners <- zipGenIDs state [ c | Just c <- allCorners, distance c (roomMean r) <= cutoff ]

  if -- If no points have been selected so far and there are only 8 suggestions, directly use those
    | roomCorners r == [] && length suggestedCorners == 8 -> do
        putStrLn "Only have 8 corners from the 6 planes - you have no choice"
        updateRoom state r{ roomCorners = suggestedCorners }
    | otherwise -> do
        putStrLn $ "Suggesting " ++ show (length allCorners) ++ " corners from " ++ show (length planes) ++ " planes"
        updateRoom state r{ roomSuggestedCorners = suggestedCorners }


acceptCornerSuggestion :: State -> Room -> ID -> IO ()
acceptCornerSuggestion state r suggID = do
  putStrLn $ "Accepting corner suggestion " ++ show suggID ++ " to room " ++ show (roomID r)
  let Just sugg = find (\(i, _) -> i == suggID) (roomSuggestedCorners r)
  addCornerToRoom state sugg r


-- | Calculates the rotation matrix that will rotate plane1 into the same
-- direction as plane 2.
--
-- Note that if you actually want to rotate plane 2 onto plane 1, you have
-- to take the inverse or pass them the other way around!
rotationBetweenPlaneEqs :: PlaneEq -> PlaneEq -> Mat3
rotationBetweenPlaneEqs (PlaneEq n1 _) (PlaneEq n2 _) = o -- TODO change this to take Normal3 directly instead of planeEqs
  where
    -- TODO Use http://lolengine.net/blog/2013/09/18/beautiful-maths-quaternion-from-vectors
    o = rotMatrix3' axis theta
    axis = crossprod n1 n2
    costheta = dotprod n1 n2 / (norm n1 * norm n2)
    theta = acos costheta


rotatePlaneEq :: Mat3 -> PlaneEq -> PlaneEq
rotatePlaneEq rotMat (PlaneEq n d) = mkPlaneEq n' d'
  where
    n' = fromNormal n .* rotMat
    d' = d -- The distance from plane to origin does
           -- not change when rotating around origin.


rotatePlaneEqAround :: Vec3 -> Mat3 -> PlaneEq -> PlaneEq
rotatePlaneEqAround rotCenter rotMat (PlaneEq n d) = mkPlaneEq n' d'
  where
    -- See http://stackoverflow.com/questions/7685495
    n' = fromNormal n .* rotMat
    o = d *& fromNormal n
    o' = rotateAround rotCenter rotMat o
    d' = o' `dotprod` n' -- distance from origin along NEW normal vector


-- | Rotates a point around a rotation center.
rotateAround :: Vec3 -> Mat3 -> Vec3 -> Vec3
rotateAround rotCenter rotMat p = ((p &- rotCenter) .* rotMat) &+ rotCenter


rotatePlaneAround :: Vec3 -> Mat3 -> Plane -> Plane
rotatePlaneAround rotCenter rotMat p@Plane{ planeEq = oldEq, planeBounds = oldBounds }
  = p{ planeEq     = rotatePlaneEqAround rotCenter rotMat oldEq
     , planeBounds = V.map (rotateAround rotCenter rotMat) oldBounds }


rotatePlane :: Mat3 -> Plane -> Plane
rotatePlane rotMat p = rotatePlaneAround (planeMean p) rotMat p


pointMean :: Vector Vec3 -> Vec3
pointMean points | V.null points = error "pointMean: empty"
                 | otherwise     = c
  where
    n = V.length points
    c = V.foldl' (&+) zero points &* (1 / fromIntegral n)  -- bound center


cloudMean :: Cloud -> Vec3
cloudMean Cloud{ cloudPoints } = pointMean cloudPoints


planeMean :: Plane -> Vec3
planeMean Plane{ planeBounds } = pointMean planeBounds


findRoomContainingPlane :: [Room] -> ID -> Maybe Room
findRoomContainingPlane rooms i = find (\r -> any ((i == ) . planeID) (roomPlanes r)) rooms


findRoomContainingSuggestedCorner :: [Room] -> ID -> Maybe Room
findRoomContainingSuggestedCorner rooms i = find (\r -> any ((i == ) . fst) (roomSuggestedCorners r)) rooms


withSelectedRoom :: State -> (Room -> IO ()) -> IO ()
withSelectedRoom State{ transient = TransientState{ .. } } f = do
  get sSelectedRoom >>= \case
    Nothing -> putStrLn "no room selected"
    Just i -> Map.lookup i <$> get sRooms >>= \case
      Nothing -> putStrLn $ "WARNING: Room with ID " ++ show i ++ " does not exist"
      Just r -> f r


rotateSelectedPlanes :: State -> IO ()
rotateSelectedPlanes state@State{ transient = TransientState{..}, ..} = do
  get sSelectedPlanes >>= \case
    [pid1, pid2] -> do
      -- We want to rotate p1.
      [Just p1, Just p2] <- mapM (getAnyPlaneID state) [pid1, pid2]

      -- First check if p1 is part of a room.
      rooms <- Map.elems <$> get sRooms
      case findRoomContainingPlane rooms pid1 of
        Just oldRoom -> do
          let rot = rotationBetweenPlaneEqs (planeEq p1) (flipPlaneEq $ planeEq p2)

          putStrLn $ "Rotating room by " ++ show rot
          updateRoom state (rotateRoom rot oldRoom)

        Nothing -> do
          let p1' = rotatePlane rot p1
              rot = rotationBetweenPlaneEqs (planeEq p1) (planeEq p2)
          putStrLn $ "Rotating plane"
          addPlane state p1'

    ps -> putStrLn $ show (length ps) ++ " planes selected, need 2"

  -- Reset selected planes in any case
  sSelectedPlanes $= []


rotateCloudAround :: Vec3 -> Mat3 -> Cloud -> Cloud
rotateCloudAround rotCenter rotMat c@Cloud{ cloudPoints = oldPoints }
  = c { cloudPoints = V.map (rotateAround rotCenter rotMat) oldPoints }


roomMean :: Room -> Vec3
roomMean Room{ roomCloud } = cloudMean roomCloud


rotateRoomAround :: Vec3 -> Mat3 -> Room -> Room
rotateRoomAround rotCenter rotMat r@Room{ roomPlanes = oldPlanes, roomCloud = oldCloud, roomCorners = oldCorners, roomSuggestedCorners = oldSuggs, roomProj = oldProj }
  = r{ roomPlanes = map (rotatePlaneAround rotCenter rotMat) oldPlanes
     , roomCloud = rotateCloudAround rotCenter rotMat oldCloud
     , roomCorners          = [ (i, rotateAround rotCenter rotMat c) | (i, c) <- oldCorners ]
     , roomSuggestedCorners = [ (i, rotateAround rotCenter rotMat c) | (i, c) <- oldSuggs ]
     -- `linear rotMat` is right-multiplied since we use right-multiplication
     -- for everything else as well (otherwise we'd have to transpose it).
     , roomProj = translate4 rotCenter . (.*. linear rotMat) . translate4 (neg rotCenter) $ oldProj
     }

rotateRoom :: Mat3 -> Room -> Room
rotateRoom rotMat r = rotateRoomAround (roomMean r) rotMat r


translatePlaneEq :: Vec3 -> PlaneEq -> PlaneEq
-- translatePlaneEq off (PlaneEq n d) = PlaneEq n d' -- TODO this is ok but needs comment
translatePlaneEq off (PlaneEq n d) = mkPlaneEq (fromNormal n) d'
  where
    -- See http://stackoverflow.com/questions/7685495
    o = d *& fromNormal n
    o' = o &+ off
    d' = o' `dotprod` fromNormal n -- distance from origin along normal vector


translatePlane :: Vec3 -> Plane -> Plane
translatePlane off p@Plane{ planeEq = oldEq, planeBounds = oldBounds }
  = p{ planeEq     = translatePlaneEq off oldEq
     , planeBounds = V.map (off &+) oldBounds }


translateCloud :: Vec3 -> Cloud -> Cloud
translateCloud off c@Cloud{ cloudPoints = oldPoints }
  = c { cloudPoints = V.map (off &+) oldPoints }


translateRoom :: Vec3 -> Room -> Room
translateRoom off room@Room{ roomPlanes = oldPlanes, roomCloud = oldCloud, roomCorners = oldCorners, roomSuggestedCorners = oldSuggs, roomProj = oldProj }
  = room{ roomPlanes = map (translatePlane off) oldPlanes
        , roomCloud = translateCloud off oldCloud
        , roomCorners          = [ (i, c &+ off) | (i, c) <- oldCorners ]
        , roomSuggestedCorners = [ (i, c &+ off) | (i, c) <- oldSuggs ]
        , roomProj = translate4 off oldProj
        }


projectRoom :: Proj4 -> Room -> Room
projectRoom proj room@Room{ roomPlanes = oldPlanes, roomCloud = oldCloud, roomCorners = oldCorners, roomSuggestedCorners = oldSuggs, roomProj = oldProj }
  = room -- `roomProj` is always a projection versus the origin, so rotate around that.
        { roomPlanes = map (translatePlane off . rotatePlaneAround zero rotMat) oldPlanes
        , roomCloud = (translateCloud off . rotateCloudAround zero rotMat) oldCloud
        -- TODO Change this so that it doesn't assume the scaling factor is 1 (so scale the result)
        , roomCorners          = [ (cid, myTrim . (.* fromProjective proj) . (extendWith 1 :: Vec3 -> Vec4) $ corner) | (cid, corner) <- oldCorners ]
        , roomSuggestedCorners = [ (cid, myTrim . (.* fromProjective proj) . (extendWith 1 :: Vec3 -> Vec4) $ corner) | (cid, corner) <- oldSuggs ]
        , roomProj = oldProj .*. proj
        }
  where
    myTrim (Vec4 x y z 1) = Vec3 x y z
    myTrim _              = error "myTrim"
    Mat4 (Vec4  a  b  c 0)
         (Vec4  d  e  f 0)
         (Vec4  g  h  i 0)
         (Vec4 tx ty tz 1) = fromProjective proj
    off = Vec3 tx ty tz
    rotMat = Mat3 (Vec3 a b c) (Vec3 d e f) (Vec3 g h i)


-- Clouds recored with Kinfu clouds are always heads-up.
rotateKinfuRoom :: Room -> Room
rotateKinfuRoom = rotateRoom (rotMatrixX (toRad 180))


loadRoom :: State -> FilePath -> IO Room
loadRoom state dir = do
  let path = dir </> "cloud_downsampled.pcd"

  cloud <- cloudFromFile state path

  -- Make all plane normals inward facing
  let roomCenter = cloudMean cloud
      makeInwardFacing p@Plane{ planeEq = PlaneEq n d }
        = p{ planeEq = let inwardVec = roomCenter &- planeMean p -- TODO use one point on plane instead of planeMean
                           pointsInward = inwardVec `dotprod` fromNormal n > 0
                        in if pointsInward then PlaneEq n d
                                           else PlaneEq (flipNormal n) (-d)
           }

  planes <- map makeInwardFacing <$> planesFromDir state dir

  i <- genID state
  let room = Room i planes cloud [] [] one path
  updateRoom state room
  -- Note that we should not further modify the room in this function,
  -- since we desire that loadRoom returns it both as represented in
  -- the data file and with `roomProj` set to identity.
  putStrLn $ "Room " ++ show i ++ " loaded"
  return room


getRoom :: State -> ID -> IO (Maybe Room)
getRoom State{ transient = TransientState { sRooms } } i = Map.lookup i <$> get sRooms


changeRoom :: State -> ID -> (Room -> Room) -> IO ()
changeRoom state@State{ transient = TransientState { sRooms } } i f = do
  getRoom state i >>= \case
    Nothing -> putStrLn "no room loaded"
    Just r -> do
      let r' = f r
      sRooms $~ Map.insert i r'
      updatePointCloud state (roomCloud r')


updateRoom :: State -> Room -> IO ()
updateRoom state@State{ transient = TransientState{ sRooms } } room = do
  sRooms $~ Map.insert (roomID room) room
  updatePointCloud state (roomCloud room)


addPlane :: State -> Plane -> IO ()
addPlane State{ transient = TransientState{ sPlanes } } p@Plane{ planeID = i } = do
  sPlanes $~ (Map.insert i p)


fitCuboidToSelectedRoom :: State -> IO ()
fitCuboidToSelectedRoom state = do
  withSelectedRoom state (fitCuboidToRoom state)


makeSelectedRoomPointsPickable :: State -> IO ()
makeSelectedRoomPointsPickable state@State{ transient = TransientState{ sPickablePoints } } = do
  withSelectedRoom state $ \Room{ roomCloud = Cloud{ cloudPoints } } -> do
    idsPoints <- zipGenIDs state (V.toList cloudPoints)
    atomicModifyIORef_ sPickablePoints (Map.fromList idsPoints `Map.union`)


planeFromSelectedPoints :: State -> IO ()
planeFromSelectedPoints state@State{ transient = TransientState{ sSelectedPoints } } = do
  get sSelectedPoints >>= \case
    ps | length ps < 3 -> putStrLn $ show (length ps) ++ " points selected, need at least 3"
    ps -> withSelectedRoom state $ \r -> do
      i <- genID state
      let planeEq = fitPlane (V.fromList ps)
          plane   = Plane i planeEq red (V.map (projectToPlane planeEq) $ V.fromList ps)
      updateRoom state r{ roomPlanes = plane : roomPlanes r }
      sSelectedPoints $= []


fitCuboidToRoom :: State -> Room -> IO ()
fitCuboidToRoom state@State{ transient = TransientState{ sConnectedWalls } }
                Room{ roomID, roomCorners, roomPlanes = oldRoomPlanes } = do
  putStrLn $ "fitting cuboid to room " ++ show roomID

  if length roomCorners < 8
    then putStrLn "not enough room corners; need 8"
    else do
      putStrLn $ "Room corners: " ++ show roomCorners

      let points = map (toDoubleVec . snd) roomCorners
          (params, steps, err, _) = fitCuboidFromCenterFirst points

      putStrLn $ "fit cuboid in " ++ show steps ++ " steps, RMSE: " ++ show (sqrt err)

      -- Replace room planes and corners by those of the cuboid

      let cuboidPoints = map toFloatVec $ cuboidFromParams params
          [x,y,z, a,b,c, q1,q2,q3,q4] = map toFloat params

      cuboidPlanes <- makePlanesFromCuboid state cuboidPoints
                                           (Vec3 x y z) (Vec3 a b c)
                                           (mkU (Vec4 q1 q2 q3 q4))

      -- Re-use corner ids
      let newCorners = [ (i, corner) | corner <- cuboidPoints | (i, _) <- roomCorners ]

      changeRoom state roomID (\r -> r{ roomCorners = newCorners
                                      , roomPlanes  = cuboidPlanes })

      -- The room now has new planes, we have to remove the old wall IDs from
      -- sConnectedWalls.
      let oldPlaneIDs = map planeID oldRoomPlanes
      sConnectedWalls $~ \ws -> [ w | w@(_, _, pidA, pidB) <- ws
                                    , pidA `notElem` oldPlaneIDs
                                    , pidB `notElem` oldPlaneIDs]


makePlanesFromCuboid :: State -> [Vec3] -> Vec3 -> Vec3 -> UnitQuaternion -> IO [Plane]
makePlanesFromCuboid state cuboidPoints cuboidCenter _cuboidDims@(Vec3 a b c) rotQuat = do

  px1 <- fromOriginPlane (mkPlaneEq (Vec3   1    0    0 ) (a/2))
  px2 <- fromOriginPlane (mkPlaneEq (Vec3 (-1)   0    0 ) (a/2))
  py1 <- fromOriginPlane (mkPlaneEq (Vec3   0    1    0 ) (b/2))
  py2 <- fromOriginPlane (mkPlaneEq (Vec3   0  (-1)   0 ) (b/2))
  pz1 <- fromOriginPlane (mkPlaneEq (Vec3   0    0    1 ) (c/2))
  pz2 <- fromOriginPlane (mkPlaneEq (Vec3   0    0  (-1)) (c/2))

  return [px1, px2, py1, py2, pz1, pz2]

  where
    rotMat = fromOrtho $ rightOrthoU rotQuat

    -- We first construct the planes as if the room was centered at
    -- the origin and the planes orthogonal to the axes, and then
    -- adjust the room to the center and rotation we got from the
    -- cuboid fitting.
    fromOriginPlane originEq = do
      i   <- genID state
      col <- getRandomColor
      let eq = translatePlaneEq cuboidCenter . rotatePlaneEqAround zero rotMat $ originEq

          reorderPolygon corners = let c1:rest = corners
                                       [c2,c3,c4] = sortBy (comparing (distance c1)) rest
                                    in [c1,c2,c4,c3]
          bounds =   V.fromList
                   . reorderPolygon
                   . (\l -> assert (length l == 4) l)
                   . filter ((< 1e-4) . abs . signedDistanceToPlaneEq eq)
                   $ cuboidPoints

      return $ Plane i eq col bounds


toFloatVec :: Vect.Double.Vec3 -> Vec3
toFloatVec (Vect.Double.Vec3 a b c) = Vec3 (realToFrac a) (realToFrac b) (realToFrac c)

toDoubleVec :: Vec3 -> Vect.Double.Vec3
toDoubleVec (Vec3 a b c) = Vect.Double.Vec3 (realToFrac a) (realToFrac b) (realToFrac c)


roomAutoAlignAxis :: State -> Vec3 -> Room -> IO ()
roomAutoAlignAxis state axis room@Room{ roomID, roomPlanes } = do
  putStrLn $ "auto aligning floor of room " ++ show roomID

  case roomPlanes of
    [] -> putStrLn "room has no planes"
    ps -> do
      let floorPlane = maximumBy (comparing (dotprod axis . planeNormal)) ps
          rot = rotationBetweenPlaneEqs (planeEq floorPlane) (mkPlaneEq axis 1)

      updateRoom state (rotateRoom rot room)


-- TODO change this to use the lowest plane instead of the one most parallel to the floor
autoAlignFloor :: State -> Room -> IO ()
autoAlignFloor state room = roomAutoAlignAxis state vec3Y room


newEmptyCloud :: State -> IO Cloud
newEmptyCloud state = do
  i <- genID state
  return $ Cloud i (OneColor red) (V.empty)


save :: State -> IO ()
save state = saveTo state "save.safecopy"


saveTo :: State -> FilePath -> IO ()
saveTo State{ transient = TransientState{..} } path = do
  putStrLn $ "Saving rooms to " ++ path
  rooms <- get sRooms
  connectedWalls <- get sConnectedWalls
  BS.writeFile path . runPut . safePut $ Save
    { saveRooms = rooms
    , saveConnectedWalls = connectedWalls
    }
  putStrLn "saved"


load :: State -> IO ()
load state = loadFrom state "save.safecopy"


loadFrom :: State -> FilePath -> IO ()
loadFrom state@State{ transient = TransientState{..} } path = do
  putStrLn $ "Loading rooms from " ++ path
  try (BS.readFile path) >>= \case
    Left (e :: IOError) -> print e
    Right bs -> case runGet safeGet bs of

      Right s -> loadSave s

      Left nonLegacyErr -> do
        -- Try legacy load where only the Map ID Room was in the bytestring
        case runGet safeGet bs of
          Left _ -> putStrLn $ "Failed loading " ++ path ++ ": " ++ nonLegacyErr -- use the non legacy error message here
          Right (rooms :: Map ID Room) -> do
            putStrLn "Legacy load succeeded!"
            loadSave $ migrate Save_v1{ saveRooms_v1 = rooms }
  where
    loadSave :: Save -> IO ()
    loadSave s = do
      -- Make sure we don't get ID conflicts by bumping the IDs of loaded
      -- objects higher than sNextID.
      nextID <- get sNextID

      -- Note that bumping by nextID is a bit more than needed since
      -- our IDs currently start at 1, but who cares.
      let saveWithBumpedIDs = bumpIDsBy nextID s
          newNextID = maximum (getIDs saveWithBumpedIDs) + 1

      sNextID $= newNextID

      loadIDsAdjustedSave saveWithBumpedIDs

    loadIDsAdjustedSave :: Save -> IO ()
    loadIDsAdjustedSave Save{ saveRooms, saveConnectedWalls } = do
      sRooms $= saveRooms
      forM_ (Map.elems saveRooms) (updateRoom state) -- allocates room clouds
      sConnectedWalls $= saveConnectedWalls


clearRooms :: State -> IO ()
clearRooms State{ transient = TransientState{ sRooms, sConnectedWalls, sAllocatedClouds } } = do
  putStrLn "Clearing"
  roomClouds <- map roomCloud . Map.elems <$> get sRooms

  sRooms $= Map.empty

  forM_ roomClouds $ \Cloud{ cloudID } -> do
    putStrLn $ "Deallocating room cloud " ++ show cloudID
    allocatedClouds <- get sAllocatedClouds

    case Map.lookup cloudID allocatedClouds of
      Nothing -> putStrLn $ "Warning: clearRooms: cloud " ++ show cloudID ++ " does not exist"
      Just (_, bufObj, m'colorObj) -> do
        deleteObjectName bufObj
        for_ m'colorObj deleteObjectName
        sAllocatedClouds $~ Map.delete cloudID

  sConnectedWalls $= []


clearSelections :: State -> IO ()
clearSelections State{ transient = TransientState{..}, ..} = do
  sSelectedPlanes $= []
  sSelectedRoom $= Nothing
  sSelectedPlanes $= []
  putStrLn "selections cleared"


swapRoomPositions :: State -> IO ()
swapRoomPositions state@State{ transient = TransientState{..}, ..} = do
  get sSelectedPlanes >>= \case
    [pid1, pid2] -> do
      rooms <- Map.elems <$> get sRooms
      case (findRoomContainingPlane rooms pid1, findRoomContainingPlane rooms pid2) of
        (Just room1, Just room2) -> do
          putStrLn $ "Swapping rooms " ++ show (roomID room1, roomID room2)
          let m1 = roomMean room1
              m2 = roomMean room2
          -- Swap the two rooms
          changeRoom state (roomID room1) (translateRoom (m2 &- m1))
          changeRoom state (roomID room2) (translateRoom (m1 &- m2))
        _ -> do
          putStrLn $ "The planes " ++ show (pid1, pid2) ++ " are not walls of different rooms!"

    ps -> putStrLn $ show (length ps) ++ " walls selected, need 2"

  -- Reset selected planes in any case
  sSelectedPlanes $= []


autoAlignAndRotate :: State -> IO ()
autoAlignAndRotate state = withSelectedRoom state $ \r -> do
  -- Align in order: [floor, side, floor] to make sure the side rotation
  -- doesn't move the unaligned floor somewhere else.
  autoAlignFloor state r
  roomAutoAlignAxis state vec3X r
  changeRoom state (roomID r) $ rotateRoom (rotMatrix3 vec3Y (toRad 90))
  -- Don't unselect room so that we can rotate multiple times easily


connectWalls :: State -> WallRelation -> IO ()
connectWalls state@State{ transient = TransientState{..}, ..} relation = do
  get sSelectedPlanes >>= \case
    [pid1, pid2] -> do

      rooms <- Map.elems <$> get sRooms
      case (findRoomContainingPlane rooms pid1, findRoomContainingPlane rooms pid2) of
        (Just room1, Just room2) -> do
          putStrLn $ "Connecting rooms " ++ show (roomID room1, roomID room2) ++ " via wall planes " ++ show (pid1, pid2)

          [Just p1, Just p2] <- mapM (getAnyPlaneID state) [pid1, pid2]
          let PlaneEq n1 _  = planeEq p1
              PlaneEq n2 _  = planeEq p2

          let bestAxis n = snd $ maximum [ (abs (fromNormal n `dotprod` v), ax) | (v, ax) <- [(vec3X, X), (vec3Y, Y), (vec3Z, Z)] ]

          case (bestAxis n1, bestAxis n2) of
            (a, a') | a /= a' -> putStrLn $ "Could not guess axis of wall connection"
            (axis, _)         -> do
              -- TODO improve the duplicate check
              sConnectedWalls $~ \ws -> if [ () | (_, _, pidA, pidB) <- ws, (pidA, pidB) `elem` [(pid1,pid2),(pid2,pid1)] ] /= []
                                          then ws
                                          else (axis, relation, pid1, pid2):ws
        _ -> do
          putStrLn $ "The planes " ++ show (pid1, pid2) ++ " are not walls of different rooms!"

    ps -> putStrLn $ show (length ps) ++ " walls selected, need 2"

  -- Reset selected planes in any case
  sSelectedPlanes $= []


disconnectWalls :: State -> IO ()
disconnectWalls State{ transient = TransientState{..}, ..} = do
  get sSelectedPlanes >>= \case
    [pid1, pid2] -> do

      putStrLn $ "Disconnecting walls " ++ show (pid1, pid2)

      -- Keep all the other connections that are not (pid1,pid2)
      connectedWalls <- get sConnectedWalls
      sConnectedWalls $= [ ws | ws@(_, _, pidA, pidB) <- connectedWalls
                              , (pidA,pidB) `notElem` [(pid1,pid2),(pid2,pid1)] ]

    ps -> putStrLn $ show (length ps) ++ " walls selected, need 2"

  -- Reset selected planes in any case
  sSelectedPlanes $= []


optimizeRoomPositions :: State -> IO ()
optimizeRoomPositions state@State{ transient = TransientState{..} } = do
  rooms <- Map.elems <$> get sRooms
  conns <- get sConnectedWalls

  let wallsRooms = [ (p1, p2, r1, r2, axis, relation)
                   | (axis, relation, pid1, pid2) <- conns
                   , let Just r1 = findRoomContainingPlane rooms pid1
                   , let Just r2 = findRoomContainingPlane rooms pid2
                   , let [p1] = [ p | p <- roomPlanes r1, planeID p == pid1 ]
                   , let [p2] = [ p | p <- roomPlanes r2, planeID p == pid2 ]
                   ]

  when ([ () | (_, _, r1, r2, _, _) <- wallsRooms, roomCorners r1 == [] || roomCorners r2 == [] ] /= []) $
    error "some room in position optimization has no corners!"

  -- We optimize translations along the 3 axes separately (they are independent).
  -- That means that we we only have to work on one component of any 3D point
  -- involved, which we get with `getComponent axis`.
  forM_ [X,Y,Z] $ \axis -> do

    let -- Each connected wall expresses a desired distance between two rooms.
        desiredCenterOffsets :: [ ((ID, ID), Double) ]
        desiredCenterOffsets =
          [ ((roomID r1, roomID r2), realToFrac $ o + signum o * wallDistance)
          | (p1, p2, r1, r2, ax, relation) <- wallsRooms, ax == axis
          , let o = roomCenterOffsetFromWalls r1 r2 p1 p2 axis
          , let wallDistance = case relation of Opposite d -> d
                                                Same       -> 0
          ]

    -- Check if there is any room to move on this axis
    case [ r | (_,_,r,_,ax,_) <- wallsRooms, ax == axis ] of
      [] -> putStrLn $ "Don't need to align along " ++ show axis ++ " axis"
      firstRoom:_ -> do

        -- Underconstrained positions:
        --
        -- If the room connections do not fully constrain the optimal room
        -- positions along `axis`, there are problems:
        --
        -- If we are working on an axis and have 4 rooms that are connected
        -- pairwise and independent of each other, say A-B C-D, then
        -- lstSqDistances will set both A and C to 0 and thus have them
        -- fall together. In other cases, having too few constraints might
        -- move the "free" rooms to arbitrary positions (in practice, it seems
        -- to pick 0 or hugely positive/negative numbers).
        --
        -- We prevent these problems by doing the optimisation separately within
        -- the connected components of the room connection graph (of `axis`).
        -- That way, each system is never underconstrained.
        let connectedComponents = groupConnectedComponents desiredCenterOffsets

        putStrLn $ "Aligning the " ++ show axis ++ " (" ++ show (length connectedComponents) ++ " components)"

        forM_ connectedComponents $ \comp -> do

          -- For the current connected component of the connection graph for
          -- `axis`, find the optimal position of each room.
          -- This returns the first room being 0 along the axis, and the other rooms
          -- at positions that minimize the square error from the desired distances.
          case lstSqDistances (Map.fromList comp) of
            Nothing -> putStrLn "WARNING: optimizeRoomPositions singularity error"
            Just (newRoomCentersDouble, rmse) -> do

              let newRoomCenters :: Map ID Float
                  newRoomCenters = realToFrac <$> newRoomCentersDouble

              putStrLn $ "Aligned component of " ++ show axis ++ " axis with RMSE " ++ (printf "%.3f" rmse)

              -- We want the first room to be at its original position instead of at 0,
              -- so shift the optimized room positions by that original position.
              let firstRoomCenterComp = getComponent axis $ cornerMean firstRoom
                  newRoomCentersFromFirst = (+ firstRoomCenterComp) <$> newRoomCenters

              -- Translate all rooms to their new positions.
              forM_ (Map.toList newRoomCentersFromFirst) $ \(rid, newRoomCenterComp) -> do
                changeRoom state rid $ \r ->
                  let oldRoomCenterComp = getComponent axis (cornerMean r)
                   in translateRoom ( (newRoomCenterComp - oldRoomCenterComp) `along` axis) r


getComponent :: Axis -> Vec3 -> Float
getComponent X (Vec3 x _ _) = x
getComponent Y (Vec3 _ y _) = y
getComponent Z (Vec3 _ _ z) = z


along :: Float -> Axis -> Vec3
d `along` X = Vec3 d 0 0
d `along` Y = Vec3 0 d 0
d `along` Z = Vec3 0 0 d


cornerMean :: Room -> Vec3
cornerMean = pointMean . V.fromList . map snd . roomCorners


-- Assumes rooms are perfect cuboids.
roomCenterOffsetFromWalls :: Room -> Room -> Plane -> Plane -> Axis -> Float
roomCenterOffsetFromWalls r1 r2 p1 p2 axis
  = getComponent axis $ (planeMean p1 &- cornerMean r1) &- (planeMean p2 &- cornerMean r2)


exportRoomProjection :: State -> IO ()
exportRoomProjection state = do
  withSelectedRoom state (putStrLn . roomProjectionToString)


switchMoveTarget :: State -> IO ()
switchMoveTarget state@State{ transient = TransientState{ sMoveTarget } } = do
  setMoveTarget state . cycleEnum =<< get sMoveTarget


setMoveTarget :: State -> MoveTarget -> IO ()
setMoveTarget State{ transient = TransientState{ sMoveTarget } } t = do
  sMoveTarget $= t
  putStrLn $ "Move target: " ++ show t


duplicateSelectedPlane :: State -> IO ()
duplicateSelectedPlane state@State{ transient = TransientState{..} } = do
  get sSelectedPlanes >>= \case
    [pid] -> do
      putStrLn $ "Duplicating wall " ++ show pid

      Just p <- getAnyPlaneID state pid
      i <- genID state
      let dupPlane = p{ planeID = i }

      rooms <- Map.elems <$> get sRooms
      case findRoomContainingPlane rooms (planeID p) of
        Just r -> updateRoom state r{ roomPlanes = dupPlane : roomPlanes r }
        _      -> sPlanes $~ Map.insert (planeID dupPlane) dupPlane
    ps -> putStrLn $ show (length ps) ++ " walls selected, need 1"


moveDirection :: State -> Vec3 -> IO ()
moveDirection state@State{ transient = TransientState{..}, ..} directionVec = do
  get sMoveTarget >>= \case
    MoveRoom -> withSelectedRoom state $ \r -> do
      updateRoom state (translateRoom directionVec r)
    MoveWall -> do
      get sSelectedPlanes >>= \case
        [pid] -> do
          Just p <- getAnyPlaneID state pid

          step <- get sWallMoveStep
          let movedPlane = translatePlane (step *& directionVec) p

          rooms <- Map.elems <$> get sRooms
          case findRoomContainingPlane rooms (planeID p) of
            Just r -> do
              let oldPlaneCorners   = V.toList (planeBounds p)
                  movedPlaneCorners = V.toList (planeBounds movedPlane)
              updateRoom state r
                { roomPlanes = movedPlane : [ x | x <- roomPlanes r, x /= p ]
                -- Also move the room corners if they were on the plane
                -- Note: This is very fragile since floating-point comparison.
                --       It works because the planes were created from the corners.
                -- This does not fix the cuboid if one has already been fitted
                -- to the room - the user has to fit it again after moving.
                , roomCorners = if all (`elem` map snd (roomCorners r)) oldPlaneCorners
                                  then [ (i, fromMaybe c . lookup c $ zip oldPlaneCorners movedPlaneCorners)
                                       | (i, c) <- roomCorners r ]
                                  else roomCorners r
                }
            _ -> do
              sPlanes $~ Map.insert (planeID p) movedPlane
        [] -> putStrLn "Nothing selected"
        ps -> putStrLn $ show (length ps) ++ " walls selected, need 1"


-- Convenience
moveAllRooms :: State -> Vec3 -> IO ()
moveAllRooms state@State{ transient = TransientState { sRooms } } directionVec = do
  rooms <- Map.elems <$> get sRooms

  forM_ rooms $ \r -> do
    updateRoom state (translateRoom directionVec r)


roomProjectionToString :: Room -> String
roomProjectionToString Room{ roomProj }
  = intercalate "," $ map show [a,b,c,d
                               ,e,f,g,h
                               ,i,j,k,l
                               ,m,n,o,p]
  where
    -- `roomProj :: Proj4` uses right-multiplication and so stores the
    -- 4x4 transposed to how most applications deal with it. We want to
    -- export the left-multiplicative form, so we have to transpose.
    Mat4 (Vec4 a b c d)
         (Vec4 e f g h)
         (Vec4 i j k l)
         (Vec4 m n o p) = transpose $ fromProjective roomProj


-- | Formats in the the .xf file format, as used for the `plyxform` tool for
-- transforming .ply files.
roomProjectionToXfFormat :: Room -> String
roomProjectionToXfFormat Room{ roomProj }
  = unlines $ map (unwords . (map show)) [[a,b,c,d]
                                         ,[e,f,g,h]
                                         ,[i,j,k,l]
                                         ,[m,n,o,p]]
  where
    -- `roomProj :: Proj4` uses right-multiplication and so stores the
    -- 4x4 transposed to how most applications deal with it. We want to
    -- export the left-multiplicative form, so we have to transpose.
    Mat4 (Vec4 a b c d)
         (Vec4 e f g h)
         (Vec4 i j k l)
         (Vec4 m n o p) = transpose $ fromProjective roomProj


exportAllRoomPCLTransforms :: State -> IO ()
exportAllRoomPCLTransforms State{ transient = TransientState{ sRooms } } = do
  rooms <- Map.elems <$> get sRooms

  forM_ rooms $ \r -> do

    putStrLn $ "~/src/pcl/pcl/build/bin/pcl_transform_point_cloud "
               ++ roomName r ++ " " ++ (takeFileName . takeDirectory . takeDirectory $ roomName r) ++ "-placed.pcd"
               ++ " -matrix " ++ roomProjectionToString r


exportAllRoomXfFiles :: State -> IO ()
exportAllRoomXfFiles State{ transient = TransientState{ sRooms } } = do
  rooms <- Map.elems <$> get sRooms

  createDirectoryIfMissing False "xf"

  forM_ rooms $ \r -> do

    print (roomName r)
    writeFile ("xf" </> (takeFileName . takeDirectory $ roomName r) ++ ".xf") (roomProjectionToXfFormat r)


-- Infinite list of Cantor pairs:
-- `(0 0) (0 1) (1 0) (0 2) (1 1) (2 0) (0 3) (1 2) (2 1) ...`
diagonalPairs :: [ (Int, Int) ]
diagonalPairs = [ (a, n-1-a) | n <- [1..], a <- [0..n-1] ]


devSetup :: State -> IO ()
devSetup state = do
  -- Coord planes
  pid1 <- genID state
  pid2 <- genID state
  pid3 <- genID state
  addPlane state (Plane pid1 (PlaneEq (mkNormal $ Vec3 1 0 0) 0) (Color3 1 0 0) (V.fromList [Vec3 0 0 0, Vec3 0 5 0, Vec3 0 5 5, Vec3 0 0 5]))
  addPlane state (Plane pid2 (PlaneEq (mkNormal $ Vec3 0 1 0) 0) (Color3 0 1 0) (V.fromList [Vec3 0 0 0, Vec3 5 0 0, Vec3 5 0 5, Vec3 0 0 5]))
  addPlane state (Plane pid3 (PlaneEq (mkNormal $ Vec3 0 0 1) 0) (Color3 0 0 1) (V.fromList [Vec3 0 0 0, Vec3 0 5 0, Vec3 5 5 0, Vec3 5 0 0]))

  let baseDir = "/home/niklas/uni/individualproject/recordings/rec3"

      rooms =
        [ ("elabathroom1"
          , [ Vec3 (-0.80041015) (-0.9884287) (-1.5198468)
            , Vec3 (-0.80076337) 1.5652194 (-1.6966621)
            , Vec3 (-0.96627235) 1.6066637 1.6987381
            , Vec3 (-0.95966613) (-0.98843944) 1.7501512
            , Vec3 0.5775635 (-0.98843974) 1.8941374
            , Vec3 0.69802976 1.5778129 (-1.5970236)
            , Vec3 0.6918931 (-0.9884289) (-1.4197717)
            , Vec3 0.5793414 1.6201758 1.843245
            ]
          )
        , ("elakitchen1"
          , [ Vec3 9.671569e-2 (-0.91251373) (-2.2253428)
            , Vec3 (-2.1025066) (-0.91251373) (-1.0994778)
            , Vec3 (-2.2102604) 1.7036777 (-1.1300573)
            , Vec3 9.584594e-2 1.7212467 (-2.3112164)
            , Vec3 2.0891232 1.725184 1.2726974
            , Vec3 (-0.30790687) 1.707284 2.3521976
            , Vec3 (-0.23941708) (-0.9125142) 2.3106794
            , Vec3 2.046792 (-0.912514) 1.2810183
            ]
          )
        , ("elamiddle1"
          , [ Vec3 0.4379654 1.5980418 (-0.26340306)
            , Vec3 (-0.4265194) 1.6302242 (-0.19807673)
            , Vec3 (-0.38968277) 1.6646035 0.5294547
            , Vec3 0.4116578 1.6347461 0.4683745
            , Vec3 (-0.41408634) (-0.97689533) 0.7326498
            , Vec3 (-0.4582219) (-0.9768954) (-0.14981699)
            , Vec3 0.41233778 (-0.9768954) (-0.21617222)
            , Vec3 0.38007212 (-0.97689533) 0.66986275
            ]
          )
        , ("elaroom1"
          , [ Vec3 2.1304765 (-1.0610049) (-1.6002798)
            , Vec3 2.380793 1.5803287 (-1.5484123)
            , Vec3 (-1.6485546) 2.0091648 (-1.9336071)
            , Vec3 (-1.9732126) (-0.5630518) (-1.9919395)
            , Vec3 (-2.0735986) (-0.7954781) 2.0725145
            , Vec3 (-1.732965) 1.9079933 2.1676683
            , Vec3 1.7069712 (-1.187545) 1.8982229
            , Vec3 1.9569516 1.5288324 2.014926
            ]
          )
        , ("elarooma2"
          , [ Vec3 (-1.2394748) (-0.9991329) (-1.9200139)
            , Vec3 (-1.3578) 1.6094978 (-1.8529172)
            , Vec3 (-1.1683455) 1.2875693 2.6794243
            , Vec3 (-1.0703187) (-0.9991331) 2.472702
            , Vec3 0.8354454 1.5010788 2.7371817
            , Vec3 0.9719229 (-0.9991331) 2.5117178
            , Vec3 1.0528631 (-0.9991329) (-1.8371677)
            , Vec3 0.91312027 1.618686 (-1.7705941)
            ]
          )
        , ("elaroomb3"
          , [ Vec3 2.2902393 (-1.1796348) (-2.025272)
            , Vec3 2.3693638 (-1.1879312) 1.463068
            , Vec3 (-2.0558214) (-0.76278543) 2.231657
            , Vec3 (-2.467492) (-0.7224221) (-1.7942874)
            , Vec3 (-2.4088001) 1.9028702 (-1.733478)
            , Vec3 (-2.0076504) 1.806385 2.200717
            , Vec3 2.601904 1.4829392 1.3990588
            , Vec3 2.5302696 1.5456867 (-1.9704242)
            ]
          )
        ]

  ids <- forM (zip rooms diagonalPairs) $ \((roomName, cornersFromMean), (x,z)) -> do

    Room{ roomID = i } <- loadRoom state (baseDir </> roomName </> "walls")
    changeRoom state i $ rotateKinfuRoom
    autoAlignFloor state =<< (\(Just r) -> r) <$> getRoom state i

    changeRoom state i $ removeCeiling

    cornersFromMeanWithIDs <- zipGenIDs state cornersFromMean

    -- `cornersFromMean` were recorded after `rotateKinfuRoom`, `autoAlignFloor`, and `removeCeiling`.
    changeRoom state i $ \r -> r{ roomCorners = [ (cid, c &+ roomMean r) | (cid, c) <- cornersFromMeanWithIDs ] }

    changeRoom state i $ translateRoom (Vec3 (6 * fromIntegral x) 0 (6 * fromIntegral z))

    return i


  forM_ (zip rooms ids) $ \((roomName, _), i) -> do

    projStr <- roomProjectionToString . (\(Just r) -> r) <$> getRoom state i
    putStrLn $ "~/src/pcl/pcl/build/bin/pcl_transform_point_cloud"
               ++ " ../" ++ roomName ++ "/cloud_bin.pcd " ++ roomName ++ "-placed.pcd"
               ++ " -matrix " ++ projStr


  return ()



type RoomNamesWithCorners = [(String, [Vec3])]


groundFloorRooms :: RoomNamesWithCorners
groundFloorRooms = -- From left to right
  [ ("kueche2", [])
  , ("windfang", [])
  , ("treppeunten", [])
  , ("wohnen1-2", [])
  , ("wc1", [])
  , ("diele1", [])
  , ("bad1", [])
  , ("arbeiten1", [])
  , ("wohnen1gross", [])
  ]


firstFloorRooms :: RoomNamesWithCorners
firstFloorRooms = -- From left to right
  [ ("salon", [])
  , ("treppemitte", [])
  , ("niklas", [])
  , ("wcoben", [])
  , ("fluroben", [])
  , ("badoben", [])
  , ("schlafzimmer", [])
  , ("clara", [])
  ]


secondFloorRooms :: RoomNamesWithCorners
secondFloorRooms = -- From left to right
  [ ("badganzoben", [])
  , ("treppeganzoben", [])
  , ("kuecheganzoben", [])
  , ("flurganzoben", [])
  , ("wohnenganzoben", [])
  , ("schlafenganzoben", [])
  ]


houseSetup :: RoomNamesWithCorners -> State -> IO ()
houseSetup rooms state = do

  let baseDir = "/mnt/3d-scans/u51-walls"

  ids <- forM (zip rooms diagonalPairs) $ \((roomName, cornersFromMean), (x,z)) -> do

    Room{ roomID = i } <- loadRoom state (baseDir </> roomName)
    changeRoom state i $ rotateKinfuRoom
    autoAlignFloor state =<< (\(Just r) -> r) <$> getRoom state i

    changeRoom state i $ removeCeiling

    cornersFromMeanWithIDs <- zipGenIDs state cornersFromMean

    -- `cornersFromMean` were recorded after `rotateKinfuRoom`, `autoAlignFloor`, and `removeCeiling`.
    changeRoom state i $ \r -> r{ roomCorners = [ (cid, c &+ roomMean r) | (cid, c) <- cornersFromMeanWithIDs ] }

    changeRoom state i $ translateRoom (Vec3 (6 * fromIntegral x) 0 (6 * fromIntegral z))

    return i


  forM_ (zip rooms ids) $ \((roomName, _), i) -> do

    projStr <- roomProjectionToString . (\(Just r) -> r) <$> getRoom state i
    putStrLn $ "~/src/pcl/pcl/build/bin/pcl_transform_point_cloud"
               ++ " ../" ++ roomName ++ "/cloud_bin.pcd " ++ roomName ++ "-placed.pcd"
               ++ " -matrix " ++ projStr


  return ()


sleep :: Double -> IO ()
sleep t = threadDelay $ floor (t * 1e6)


loadTestRoom1WithCorners :: State -> IO Room
loadTestRoom1WithCorners state = do
  r@Room{ roomID = i } <- loadRoom state "/mnt/3d-scans/rec3/elaroom1/walls/"
  idCorners <- zipGenIDs state corners
  changeRoom state i (\x -> x{ roomCorners = idCorners })
  return r
  where
    corners
      = [ Vec3 0.5213087 1.3714368 0.9477334
        , Vec3 0.6015281 0.7033132 4.419407
        , Vec3 4.8369703 1.2523801 4.0971937
        , Vec3 4.4101005 1.8874655 0.5908974
        , Vec3 0.3593011 4.1540117 0.914716
        , Vec3 4.14219 4.488981 1.1421864
        , Vec3 4.5736876 3.750552 4.565998
        , Vec3 0.46467793 3.254958 4.8851647
        ]


projTest :: State -> IO ()
projTest state = do
  Room{ roomID = i } <- loadTestRoom1WithCorners state
  sleep 1
  changeRoom state i (translateRoom (Vec3 6 0 0))
  sleep 1
  changeRoom state i (rotateRoom (rotMatrix3 vec3X (toRad 90)))

  Just Room{ roomProj = proj } <- getRoom state i
  sleep 1

  Room{ roomID = i2 } <- loadTestRoom1WithCorners state
  sleep 1
  changeRoom state i2 (projectRoom proj)


projTest2 :: State -> IO ()
projTest2 state = do
  Room{ roomID = i } <- loadTestRoom1WithCorners state
  sleep 1
  changeRoom state i (rotateRoom (rotMatrix3 vec3X (toRad 10)))

  Just Room{ roomProj = proj } <- getRoom state i
  sleep 1

  Room{ roomID = i2 } <- loadTestRoom1WithCorners state
  sleep 1
  changeRoom state i2 (projectRoom proj)


projTest3 :: State -> IO ()
projTest3 state = do
  Room{ roomID = i } <- loadTestRoom1WithCorners state
  sleep 1
  autoAlignFloor state =<< (\(Just r) -> r) <$> getRoom state i
  sleep 1
  changeRoom state i (translateRoom (Vec3 6 0 0))

  Just Room{ roomProj = proj } <- getRoom state i
  sleep 1

  Room{ roomID = i2 } <- loadTestRoom1WithCorners state
  sleep 1
  changeRoom state i2 (projectRoom proj)


projTest4 :: State -> IO ()
projTest4 state = do
  Room{ roomID = i } <- loadTestRoom1WithCorners state
  sleep 1
  changeRoom state i (translateRoom (Vec3 0 0 6))
  sleep 1
  changeRoom state i (rotateRoomAround (Vec3 0 0 0) (rotMatrix3 vec3X (toRad 10)))

  Just Room{ roomProj = proj } <- getRoom state i
  sleep 1

  Room{ roomID = i2 } <- loadTestRoom1WithCorners state
  sleep 1
  changeRoom state i2 (projectRoom proj)


projTest5 :: State -> IO ()
projTest5 state = do
  Room{ roomID = i } <- loadTestRoom1WithCorners state
  sleep 1
  changeRoom state i (translateRoom (Vec3 1 2 6))

  Just Room{ roomProj = proj } <- getRoom state i
  sleep 1

  Room{ roomID = i2 } <- loadTestRoom1WithCorners state
  sleep 1
  changeRoom state i2 (projectRoom proj)


projTest6 :: State -> IO ()
projTest6 state = do
  Room{ roomID = i } <- loadTestRoom1WithCorners state
  sleep 1

  let rotMat = rotMatrix3 vec3X (toRad 10)
  changeRoom state i (rotateRoomAround (Vec3 0 0 0) rotMat)
  sleep 1

  Just Room{ roomProj = unusedProj } <- getRoom state i

  let proj = linear rotMat

  Room{ roomID = i2 } <- loadTestRoom1WithCorners state
  sleep 1
  changeRoom state i2 (projectRoom proj)

  Just Room{ roomProj = proj2 } <- getRoom state i2
  assert (proj == proj2) $ return ()
  putStrLn $ "proj   " ++ show proj
  putStrLn $ "unused " ++ show unusedProj


-- Chop of top 20% of points to peek inside
removeCeiling :: Room -> Room
removeCeiling r@Room{ roomCloud = c@Cloud{ cloudPoints = oldCloudPoints
                                         , cloudColor  = oldCloudColor } }
  = r{ roomCloud = c{ cloudPoints = newCloudPoints
                    , cloudColor  = newCloudColor } }
  where
    n = V.length oldCloudPoints
    nDiscard = n `quot` 5 -- 20%

    yComp = getComponent Y
    -- Throw away points above this limit
    yLimit = yComp $ kthLargestBy yComp nDiscard oldCloudPoints

    newCloudPoints
      | V.null oldCloudPoints = V.empty
      | otherwise             = V.filter ((<= yLimit) . yComp) oldCloudPoints

    newCloudColor = case oldCloudColor of
      col@OneColor{}  -> col
      ManyColors cols -> ManyColors $ if
        | V.null cols -> V.empty
        | otherwise   -> V.ifilter (\i _ -> yComp (oldCloudPoints ! i) <= yLimit) cols


-- | For debugging / ghci only.
dfl :: [Vec3] -> IO ()
dfl ps = do
  state <- getState
  i <- genID state
  col <- getRandomColor
  addPointCloud state (Cloud i (OneColor col) (V.fromList ps))


-- SafeCopy instances

instance SafeCopy GLfloat where
  putCopy f = contain $ safePut (realToFrac f :: Float)
  getCopy = contain $ (realToFrac :: Float -> GLfloat) <$> safeGet

instance SafeCopy a => SafeCopy (Color3 a) where
  putCopy (Color3 r g b) = contain $ do safePut r; safePut g; safePut b
  getCopy = contain $ Color3 <$> safeGet <*> safeGet <*> safeGet

deriveSafeCopy 1 'base ''Vec3
deriveSafeCopy 1 'base ''Vec4
deriveSafeCopy 1 'base ''Mat4
deriveSafeCopy 1 'base ''Proj4
deriveSafeCopy 1 'base ''CloudColor
deriveSafeCopy 1 'base ''Cloud
deriveSafeCopy 1 'base ''Normal3
deriveSafeCopy 1 'base ''PlaneEq
deriveSafeCopy 1 'base ''Plane
deriveSafeCopy 1 'base ''Room_v1
deriveSafeCopy 2 'extension ''Room_v2
instance Migrate Room_v2 where
  type MigrateFrom Room_v2 = Room_v1
  migrate (Room_v1 i planes cloud corners) = Room_v2 i planes cloud corners one
deriveSafeCopy 3 'extension ''Room_v3
instance Migrate Room_v3 where
  type MigrateFrom Room_v3 = Room_v2
  migrate (Room_v2 i planes cloud corners proj) = Room_v3 i planes cloud corners proj "ANON"
deriveSafeCopy 4 'extension ''Room
instance Migrate Room where
  type MigrateFrom Room = Room_v3
  migrate (Room_v3 i planes cloud corners proj name) = Room i planes cloud [ (0,c) | c <- corners] [] proj name -- Dirty hack

deriveSafeCopy 1 'base ''WallRelation_v1
deriveSafeCopy 2 'extension ''WallRelation
instance Migrate WallRelation where
  type MigrateFrom WallRelation = WallRelation_v1
  migrate Same_v1     = Same
  migrate Opposite_v1 = Opposite 0.1 -- global default was 10cm

deriveSafeCopy 1 'base ''Axis
deriveSafeCopy 1 'base ''Save_v1
deriveSafeCopy 2 'extension ''Save
instance Migrate Save where
  type MigrateFrom Save = Save_v1
  migrate (Save_v1 rooms) = Save rooms []
