/**
 * Card action callback listener via Feishu SDK WSClient.
 *
 * When a user clicks a follow-up question button on the answer card, the
 * callback arrives here. We extract the question text from the button's value
 * and feed it back into the gateway as if the user sent a new message.
 *
 * Requires: app has card.action.trigger event subscribed in the developer console.
 */

import * as lark from "@larksuiteoapi/node-sdk";

export interface CardCallbackHandler {
  onFollowUp: (chatId: string, question: string, messageId: string) => void;
  onMessage?: (data: unknown) => void;
}

export function startCardCallbackListener(
  appId: string,
  appSecret: string,
  handler: CardCallbackHandler,
): void {
  const dispatcher = new lark.EventDispatcher({});

  // Register card action callback.
  dispatcher.register({
    "card.action.trigger": (data: unknown) => {
      try {
        const d = data as {
          action?: { value?: { action?: string; text?: string } };
          context?: { open_chat_id?: string; open_message_id?: string };
        };
        const value = d?.action?.value;
        const chatId = d?.context?.open_chat_id ?? "";
        const messageId = d?.context?.open_message_id ?? "";

        if (value?.action === "follow_up" && value.text && chatId) {
          handler.onFollowUp(chatId, value.text, messageId);
        }
      } catch { /* best-effort */ }

      // Must return within 3 seconds; return empty object = no toast.
      return {};
    },
  });

  // Also register IM message event so the SDK WSClient doesn't steal events
  // from lark-cli (both share the same app's long connection pool).
  dispatcher.register({
    "im.message.receive_v1": (data: unknown) => {
      handler.onMessage?.(data);
      return {};
    },
  });

  const ws = new lark.WSClient({ appId, appSecret, loggerLevel: lark.LoggerLevel.warn });
  ws.start({ eventDispatcher: dispatcher });
}
