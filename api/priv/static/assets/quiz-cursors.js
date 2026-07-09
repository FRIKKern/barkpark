// Hyperquiz P2 cursor client (hq-p2-canvas).
//
// Connects to the anonymous /quiz QuizSocket, joins quiz:room:<pin>, and:
//   • (role=player) streams the pointer position, throttled to ~30Hz, as
//     normalized 0..1 coords via the "cursor" event;
//   • renders every other cursor from the server's ~15Hz binary frames
//     ("cursors") on a <canvas>, interpolating between frames for smoothness.
//
// Wire format mirrors Barkpark.Quiz.CursorFrame: <count::u16, (idx::u16,
// x::u16, y::u16)…>, coords quantized to the 16-bit grid. Decoded here.
//
// Driven by a <canvas data-quiz-pin="PIN" data-quiz-role="host|player">.
// No-op (and never throws) when no such canvas or no Phoenix global exists.
(function () {
  "use strict";

  function decodeFrame(buf) {
    var dv = new DataView(buf);
    var count = dv.getUint16(0);
    var out = {};
    var o = 2;
    for (var i = 0; i < count; i++) {
      out[dv.getUint16(o)] = {
        x: dv.getUint16(o + 2) / 65535,
        y: dv.getUint16(o + 4) / 65535
      };
      o += 6;
    }
    return out;
  }

  // Aggregate heatmap (P5): 32x32 u16 cell counts, row-major (mirror
  // Barkpark.Quiz.Heatmap). Returns {cells, max}.
  var HGRID = 32;
  function decodeHeatmap(buf) {
    var dv = new DataView(buf);
    var cells = new Array(HGRID * HGRID);
    var max = 0;
    for (var i = 0; i < HGRID * HGRID; i++) {
      var c = dv.getUint16(i * 2);
      cells[i] = c;
      if (c > max) max = c;
    }
    return { cells: cells, max: max };
  }

  function init() {
    if (typeof Phoenix === "undefined" || !Phoenix.Socket) return;
    var canvas = document.querySelector("canvas[data-quiz-pin]");
    if (!canvas) return;

    var pin = canvas.getAttribute("data-quiz-pin");
    var role = canvas.getAttribute("data-quiz-role") || "player";
    var ctx = canvas.getContext("2d");

    var COLORS = ["#e2483d", "#2b7fff", "#f5a524", "#2bb673", "#7c5cff", "#ec4899"];
    var targets = {}; // idx -> {x,y}  (latest from server, normalized)
    var shown = {}; // idx -> {x,y}    (interpolated render position)
    var heat = null; // latest decoded heatmap (above the crowd crossover)

    function resize() {
      canvas.width = canvas.clientWidth || window.innerWidth;
      canvas.height = canvas.clientHeight || window.innerHeight;
    }
    window.addEventListener("resize", resize);
    resize();

    var TOKEN_KEY = "hq_player_token";
    var savedToken = null;
    try { savedToken = window.localStorage.getItem(TOKEN_KEY); } catch (e) {}

    // Open the socket + channel with a given identity token. For a player this
    // MUST be its LiveView's signed id so the cursor socket joins as the SAME
    // player (no double-count); the host is an observer (never a player).
    function connectWith(token) {
      var socket = new Phoenix.Socket("/quiz", { params: { token: token } });
      socket.connect();

      var joinParams = role === "host" ? { observe: true } : { name: "Player" };
      var channel = socket.channel("quiz:room:" + pin, joinParams);

      channel.on("cursors", function (payload) {
        // Phoenix delivers a binary push as an ArrayBuffer.
        var buf = payload instanceof ArrayBuffer ? payload : (payload && payload.data);
        if (!buf) return;
        var frame = decodeFrame(buf);
        for (var idx in frame) targets[idx] = frame[idx];
        heat = null; // individual frames resume below the crossover
      });
      channel.on("heatmap", function (payload) {
        var buf = payload instanceof ArrayBuffer ? payload : (payload && payload.data);
        if (buf) heat = decodeHeatmap(buf);
      });
      channel.on("player_left", function (p) {
        // Evict by cursor SLOT (the frame key), not the player UUID.
        if (p && typeof p.slot !== "undefined" && p.slot !== null) {
          delete targets[p.slot];
          delete shown[p.slot];
        }
      });
      channel.join().receive("ok", function (resp) {
        if (resp && resp.player_token) {
          try { window.localStorage.setItem(TOKEN_KEY, resp.player_token); } catch (e) {}
        }
      });

      // Players stream their pointer (throttled ~30Hz).
      if (role === "player") {
        var last = 0;
        var send = function (clientX, clientY) {
          var now = Date.now();
          if (now - last < 33) return;
          last = now;
          channel.push("cursor", {
            x: Math.max(0, Math.min(1, clientX / window.innerWidth)),
            y: Math.max(0, Math.min(1, clientY / window.innerHeight))
          });
        };
        window.addEventListener("pointermove", function (e) { send(e.clientX, e.clientY); });
        window.addEventListener("touchmove", function (e) {
          if (e.touches[0]) send(e.touches[0].clientX, e.touches[0].clientY);
        }, { passive: true });
      }
    }

    if (role === "host") {
      connectWith(null);
    } else {
      // The signed identity is patched into the canvas by the LiveView AFTER it
      // connects — which (this script is `defer`) usually happens after parse.
      // Wait for it so we never connect with a stale/empty token and get counted
      // as a second player; fall back to the saved token if no LiveView sets it.
      var existing = canvas.getAttribute("data-quiz-player-token");
      if (existing) {
        connectWith(existing);
      } else {
        var started = false;
        var go = function (token) {
          if (started) return;
          started = true;
          if (obs) obs.disconnect();
          connectWith(token);
        };
        var obs = new MutationObserver(function () {
          var t = canvas.getAttribute("data-quiz-player-token");
          if (t) go(t);
        });
        obs.observe(canvas, { attributes: true, attributeFilter: ["data-quiz-player-token"] });
        // Static page (no LiveView): connect degraded after a grace period.
        window.setTimeout(function () { go(savedToken); }, 5000);
      }
    }

    // Render loop: lerp shown toward target, draw dots.
    function frame() {
      ctx.clearRect(0, 0, canvas.width, canvas.height);

      if (heat && heat.max > 0) {
        // Crowd-scale density cloud: one translucent cell per occupied bucket.
        var cw = canvas.width / HGRID;
        var ch = canvas.height / HGRID;
        for (var i = 0; i < heat.cells.length; i++) {
          var n = heat.cells[i];
          if (!n) continue;
          var cx = i % HGRID;
          var cy = (i / HGRID) | 0;
          ctx.fillStyle = "rgba(124, 92, 255, " + Math.min(0.85, 0.15 + n / heat.max) + ")";
          ctx.fillRect(cx * cw, cy * ch, cw, ch);
        }
      } else {
        for (var idx in targets) {
          var t = targets[idx];
          var s = shown[idx] || (shown[idx] = { x: t.x, y: t.y });
          s.x += (t.x - s.x) * 0.25; // interpolation factor
          s.y += (t.y - s.y) * 0.25;
          ctx.beginPath();
          ctx.arc(s.x * canvas.width, s.y * canvas.height, 7, 0, Math.PI * 2);
          ctx.fillStyle = COLORS[idx % COLORS.length];
          ctx.fill();
        }
      }
      requestAnimationFrame(frame);
    }
    requestAnimationFrame(frame);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
