// Telegram webhook for the Alem dispatch bot.
// Handles the "Confirm ride" button on new-request messages: marks the booking confirmed,
// which makes the database send the customer's confirmation email and the "Ride confirmed"
// message. Deployed as a Supabase Edge Function named `telegram-webhook` with
// "Verify JWT" turned OFF (Telegram cannot send Supabase credentials); the request is
// authenticated instead by the shared secret Telegram sends in a header.
//
// Secrets (Edge Functions -> Secrets):
//   TELEGRAM_BOT_TOKEN       the bot token from BotFather
//   TELEGRAM_CHAT_ID         the dispatch chat id; button presses from any other chat are ignored
//   TELEGRAM_WEBHOOK_SECRET  the random string registered with Telegram's setWebhook

import { withSupabase } from "npm:@supabase/server";

export default {
  fetch: withSupabase({ auth: "none" }, async (req, ctx) => {
    const secret = Deno.env.get("TELEGRAM_WEBHOOK_SECRET");
    if (secret && req.headers.get("x-telegram-bot-api-secret-token") !== secret) {
      return new Response("forbidden", { status: 403 });
    }
    const update = await req.json().catch(() => null);
    const cq = update?.callback_query;
    if (!cq) return new Response("ok");

    const token = Deno.env.get("TELEGRAM_BOT_TOKEN") ?? "";
    const tg = (method: string, body: unknown) =>
      fetch(`https://api.telegram.org/bot${token}/${method}`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(body),
      });

    const match = /^confirm:([0-9a-f-]{36})$/.exec(String(cq.data ?? ""));
    if (!match) {
      await tg("answerCallbackQuery", { callback_query_id: cq.id });
      return new Response("ok");
    }

    const allowedChat = Deno.env.get("TELEGRAM_CHAT_ID");
    const chatId = cq.message?.chat?.id;
    if (allowedChat && String(chatId) !== allowedChat) {
      await tg("answerCallbackQuery", { callback_query_id: cq.id, text: "Not allowed from this chat." });
      return new Response("ok");
    }

    const { data: rows, error } = await ctx.supabaseAdmin
      .from("bookings")
      .update({ status: "confirmed" })
      .eq("id", match[1])
      .eq("status", "new")
      .select("id");

    const who = [cq.from?.first_name, cq.from?.last_name].filter(Boolean).join(" ") || "dispatcher";
    const messageId = cq.message?.message_id;

    if (error) {
      console.error("confirm failed", error);
      await tg("answerCallbackQuery", { callback_query_id: cq.id, text: "Could not confirm right now. Please try again or use the console." });
    } else if (rows && rows.length > 0) {
      await tg("answerCallbackQuery", { callback_query_id: cq.id, text: "Ride confirmed. The customer has been notified." });
      await tg("editMessageText", {
        chat_id: chatId,
        message_id: messageId,
        text: `${cq.message?.text ?? ""}\n\nConfirmed by ${who}.`,
      });
    } else {
      await tg("answerCallbackQuery", { callback_query_id: cq.id, text: "This ride was already confirmed or is no longer pending." });
      await tg("editMessageReplyMarkup", { chat_id: chatId, message_id: messageId, reply_markup: { inline_keyboard: [] } });
    }
    return new Response("ok");
  }),
};
