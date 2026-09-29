// emoji.js — the GitHub-style shortcode table behind the `:` picker. Kept small and
// dependency-free: the names people type most, in the order GitHub lists them. A pick
// inserts the character as plain text, so nothing changes on the server.

export const EMOJI = [
  ["smile", "😄"], ["smiley", "😃"], ["grinning", "😀"], ["laughing", "😆"], ["joy", "😂"], ["rofl", "🤣"],
  ["sweat_smile", "😅"], ["wink", "😉"], ["blush", "😊"], ["innocent", "😇"], ["slightly_smiling_face", "🙂"],
  ["upside_down_face", "🙃"], ["relaxed", "☺️"], ["heart_eyes", "😍"], ["kissing_heart", "😘"], ["yum", "😋"],
  ["stuck_out_tongue", "😛"], ["stuck_out_tongue_winking_eye", "😜"], ["zany_face", "🤪"], ["thinking", "🤔"],
  ["neutral_face", "😐"], ["expressionless", "😑"], ["no_mouth", "😶"], ["smirk", "😏"], ["unamused", "😒"],
  ["rolling_eyes", "🙄"], ["grimacing", "😬"], ["relieved", "😌"], ["pensive", "😔"], ["sleepy", "😪"],
  ["sleeping", "😴"], ["mask", "😷"], ["nerd_face", "🤓"], ["sunglasses", "😎"], ["confused", "😕"],
  ["worried", "😟"], ["frowning_face", "☹️"], ["open_mouth", "😮"], ["hushed", "😯"], ["astonished", "😲"],
  ["flushed", "😳"], ["pleading_face", "🥺"], ["cry", "😢"], ["sob", "😭"], ["scream", "😱"], ["angry", "😠"],
  ["rage", "😡"], ["exploding_head", "🤯"], ["partying_face", "🥳"], ["star_struck", "🤩"], ["skull", "💀"],
  ["ghost", "👻"], ["robot", "🤖"], ["poop", "💩"], ["clown_face", "🤡"],
  ["wave", "👋"], ["raised_hand", "✋"], ["ok_hand", "👌"], ["v", "✌️"], ["crossed_fingers", "🤞"],
  ["metal", "🤘"], ["call_me_hand", "🤙"], ["point_left", "👈"], ["point_right", "👉"], ["point_up", "☝️"],
  ["point_down", "👇"], ["thumbsup", "👍"], ["+1", "👍"], ["thumbsdown", "👎"], ["-1", "👎"], ["fist", "✊"],
  ["clap", "👏"], ["raised_hands", "🙌"], ["open_hands", "👐"], ["pray", "🙏"], ["handshake", "🤝"],
  ["muscle", "💪"], ["writing_hand", "✍️"], ["eyes", "👀"], ["eye", "👁️"], ["brain", "🧠"],
  ["heart", "❤️"], ["orange_heart", "🧡"], ["yellow_heart", "💛"], ["green_heart", "💚"], ["blue_heart", "💙"],
  ["purple_heart", "💜"], ["black_heart", "🖤"], ["white_heart", "🤍"], ["broken_heart", "💔"], ["sparkling_heart", "💖"],
  ["fire", "🔥"], ["sparkles", "✨"], ["star", "⭐"], ["star2", "🌟"], ["zap", "⚡"], ["boom", "💥"],
  ["100", "💯"], ["tada", "🎉"], ["confetti_ball", "🎊"], ["balloon", "🎈"], ["gift", "🎁"], ["trophy", "🏆"],
  ["medal", "🏅"], ["rocket", "🚀"], ["airplane", "✈️"], ["car", "🚗"], ["bike", "🚲"], ["house", "🏠"],
  ["sunny", "☀️"], ["cloud", "☁️"], ["rainbow", "🌈"], ["umbrella", "☔"], ["snowflake", "❄️"], ["earth_africa", "🌍"],
  ["moon", "🌙"], ["seedling", "🌱"], ["evergreen_tree", "🌲"], ["deciduous_tree", "🌳"], ["cactus", "🌵"],
  ["four_leaf_clover", "🍀"], ["rose", "🌹"], ["sunflower", "🌻"], ["tulip", "🌷"], ["cherry_blossom", "🌸"],
  ["dog", "🐶"], ["cat", "🐱"], ["mouse", "🐭"], ["rabbit", "🐰"], ["fox_face", "🦊"], ["bear", "🐻"],
  ["panda_face", "🐼"], ["koala", "🐨"], ["lion", "🦁"], ["cow", "🐮"], ["pig", "🐷"], ["frog", "🐸"],
  ["monkey_face", "🐵"], ["chicken", "🐔"], ["penguin", "🐧"], ["bird", "🐦"], ["butterfly", "🦋"], ["bee", "🐝"],
  ["bug", "🐛"], ["snail", "🐌"], ["turtle", "🐢"], ["snake", "🐍"], ["whale", "🐳"], ["dolphin", "🐬"], ["fish", "🐟"],
  ["octopus", "🐙"], ["unicorn", "🦄"], ["dragon", "🐉"],
  ["apple", "🍎"], ["banana", "🍌"], ["grapes", "🍇"], ["strawberry", "🍓"], ["lemon", "🍋"], ["watermelon", "🍉"],
  ["avocado", "🥑"], ["bread", "🍞"], ["cheese", "🧀"], ["pizza", "🍕"], ["hamburger", "🍔"], ["fries", "🍟"],
  ["taco", "🌮"], ["sushi", "🍣"], ["ramen", "🍜"], ["cake", "🍰"], ["birthday", "🎂"], ["cookie", "🍪"],
  ["doughnut", "🍩"], ["ice_cream", "🍨"], ["coffee", "☕"], ["tea", "🍵"], ["beer", "🍺"], ["beers", "🍻"],
  ["wine_glass", "🍷"], ["champagne", "🍾"],
  ["white_check_mark", "✅"], ["heavy_check_mark", "✔️"], ["x", "❌"], ["warning", "⚠️"], ["no_entry", "⛔"],
  ["question", "❓"], ["exclamation", "❗"], ["bulb", "💡"], ["memo", "📝"], ["pencil2", "✏️"], ["book", "📖"],
  ["books", "📚"], ["bookmark", "🔖"], ["link", "🔗"], ["paperclip", "📎"], ["pushpin", "📌"], ["scissors", "✂️"],
  ["lock", "🔒"], ["unlock", "🔓"], ["key", "🔑"], ["hammer", "🔨"], ["wrench", "🔧"], ["gear", "⚙️"],
  ["hourglass", "⌛"], ["alarm_clock", "⏰"], ["calendar", "📅"], ["chart_with_upwards_trend", "📈"],
  ["chart_with_downwards_trend", "📉"], ["bar_chart", "📊"], ["clipboard", "📋"], ["package", "📦"],
  ["inbox_tray", "📥"], ["outbox_tray", "📤"], ["email", "📧"], ["envelope", "✉️"], ["phone", "📱"], ["computer", "💻"],
  ["keyboard", "⌨️"], ["desktop_computer", "🖥️"], ["floppy_disk", "💾"], ["camera", "📷"], ["video_camera", "📹"],
  ["tv", "📺"], ["headphones", "🎧"], ["microphone", "🎤"], ["musical_note", "🎵"], ["art", "🎨"], ["dart", "🎯"],
  ["game_die", "🎲"], ["soccer", "⚽"], ["basketball", "🏀"], ["tennis", "🎾"], ["mountain", "⛰️"], ["ocean", "🌊"],
  ["hourglass_flowing_sand", "⏳"], ["moneybag", "💰"], ["dollar", "💵"], ["credit_card", "💳"], ["gem", "💎"],
  ["crown", "👑"], ["mag", "🔍"], ["bell", "🔔"], ["mega", "📣"], ["speech_balloon", "💬"], ["thought_balloon", "💭"],
  ["arrow_right", "➡️"], ["arrow_left", "⬅️"], ["arrow_up", "⬆️"], ["arrow_down", "⬇️"], ["recycle", "♻️"],
  ["infinity", "♾️"], ["copyright", "©️"], ["tm", "™️"], ["construction", "🚧"], ["checkered_flag", "🏁"],
  ["triangular_flag_on_post", "🚩"], ["norway", "🇳🇴"], ["sweden", "🇸🇪"], ["denmark", "🇩🇰"], ["uk", "🇬🇧"], ["us", "🇺🇸"],
];

// The first `limit` shortcodes starting with `query` (then those containing it), as popup rows.
export function searchEmoji(query, limit = 8) {
  const q = String(query || "").toLowerCase();
  if (!q) return [];
  const starts = [];
  const contains = [];
  for (const [name, char] of EMOJI) {
    if (name.startsWith(q)) starts.push({ name, char });
    else if (name.includes(q)) contains.push({ name, char });
    if (starts.length >= limit) break;
  }
  return [...starts, ...contains].slice(0, limit);
}
