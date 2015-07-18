module IHaskell.Eval.Widgets (
    widgetSendOpen,
    widgetSendView,
    widgetSendUpdate,
    widgetSendCustom,
    widgetSendClose,
    widgetSendValue,
    relayWidgetMessages,
    widgetHandler,
    ) where

import           IHaskellPrelude

import           Control.Concurrent.Chan (writeChan)
import           Control.Concurrent.STM (atomically)
import           Control.Concurrent.STM.TChan
import           Control.Monad (foldM)
import           Data.Aeson
import qualified Data.Map as Map
import           System.IO.Unsafe (unsafePerformIO)

import           IHaskell.Display
import           IHaskell.Eval.Util (unfoldM)
import           IHaskell.IPython.Message.UUID
import           IHaskell.Types

-- All comm_open messages go here
widgetMessages :: TChan WidgetMsg
{-# NOINLINE widgetMessages #-}
widgetMessages = unsafePerformIO newTChanIO

-- | Return all pending comm_close messages
relayWidgetMessages :: IO [WidgetMsg]
relayWidgetMessages = relayMessages widgetMessages

-- | Extract all messages from a TChan and wrap them in a list
relayMessages :: TChan a -> IO [a]
relayMessages = unfoldM . atomically . tryReadTChan

-- | Write a widget message to the chan
queue :: WidgetMsg -> IO ()
queue = atomically . writeTChan widgetMessages

-- | Send a message
widgetSend :: IHaskellWidget a
           => (Widget -> Value -> WidgetMsg)
           -> a -> Value -> IO ()
widgetSend msgType widget value = queue $ msgType (Widget widget) value

-- | Send a message to open a comm
widgetSendOpen :: IHaskellWidget a => a -> Value -> Value -> IO ()
widgetSendOpen widget initVal stateVal =
  queue $ Open (Widget widget) initVal stateVal

-- | Send a state update message
widgetSendUpdate :: IHaskellWidget a => a -> Value -> IO ()
widgetSendUpdate = widgetSend Update

-- | Send a [method .= display] comm_msg
widgetSendView :: IHaskellWidget a => a -> IO ()
widgetSendView = queue . View . Widget

-- | Send a comm_close
widgetSendClose :: IHaskellWidget a => a -> Value -> IO ()
widgetSendClose = widgetSend Close

-- | Send a [method .= custom, content .= value] comm_msg
widgetSendCustom :: IHaskellWidget a => a -> Value -> IO ()
widgetSendCustom = widgetSend Custom

-- | Send a custom Value
widgetSendValue :: IHaskellWidget a => a -> Value -> IO ()
widgetSendValue widget = queue . JSONValue (Widget widget)

-- | Handle a single widget message. Takes necessary actions according to the message type, such as
-- opening comms, storing and updating widget representation in the kernel state etc.
handleMessage :: (Message -> IO ())
              -> MessageHeader
              -> KernelState
              -> WidgetMsg
              -> IO KernelState
handleMessage send replyHeader state msg = do
  case msg of
    Open widget initVal stateVal -> do
      let target = targetName widget
          uuid = getCommUUID widget
          present = isJust $ Map.lookup uuid oldComms

          newComms = Map.insert uuid widget oldComms
          newState = state { openComms = newComms }

          communicate val = do
            head <- dupHeader replyHeader CommDataMessage
            send $ CommData head uuid val

      -- If the widget is present, don't open it again.
      if present
        then return state
        else do
          -- Send the comm open
          header <- dupHeader replyHeader CommOpenMessage
          send $ CommOpen header target uuid initVal

          -- Initial state update
          communicate . toJSON $ UpdateState stateVal

          -- Send anything else the widget requires.
          open widget communicate

          -- Store the widget in the kernelState
          return newState

    Close widget value -> do
      let target = targetName widget
          uuid = getCommUUID widget
          present = isJust $ Map.lookup uuid oldComms

          newComms = Map.delete uuid $ openComms state
          newState = state { openComms = newComms }

      -- If the widget is not present in the state, we don't close it.
      if present
        then do
          header <- dupHeader replyHeader CommCloseMessage
          send $ CommClose header uuid value
          return newState
        else return state

    View widget -> sendMessage widget (toJSON DisplayWidget)

    Update widget value -> sendMessage widget (toJSON $ UpdateState value)

    Custom widget value -> sendMessage widget (toJSON $ CustomContent value)

    JSONValue widget value -> sendMessage widget value

  where
    oldComms = openComms state
    sendMessage widget value = do
      let uuid = getCommUUID widget
          present = isJust $ Map.lookup uuid oldComms

      -- If the widget is present, we send an update message on its comm.
      when present $ do
        header <- dupHeader replyHeader CommDataMessage
        send $ CommData header uuid value
      return state

-- Handle messages one-by-one, while updating state simultaneously
widgetHandler :: (Message -> IO ())
              -> MessageHeader
              -> KernelState
              -> [WidgetMsg]
              -> IO KernelState
widgetHandler sender header = foldM (handleMessage sender header)