// Thataway product page: the hero pointer, the film's pause control, and
// Vercel's analytics scripts on the deployed site only.
(() => {
  "use strict";

  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

  // ---------------------------------------------------------------------------
  // Hero pointer. A port of PointerLayer.point(from:to:) in Overlay.swift: a quad curve whose
  // control point is pushed perpendicular to the trip by min(distance * 0.28, 220), flown in
  // 0.55 s on cubic-bezier(0.16, 0.9, 0.2, 1), paced along the arc. The ring and caption fade in
  // over 0.18 s starting at 72% of the flight. Under Reduce Motion the pointer is placed at the
  // target and everything fades in, as in the app. It lands on the page's primary action once.
  // ---------------------------------------------------------------------------
  const FLIGHT_MS = 550;
  const HOLD_MS = 2600;
  const RING_INSET = 7;       // the app pads the element's bounds by 7 pt
  const RING_STROKE = 3;

  function pointOnce() {
    const hero = document.querySelector(".hero");
    const layer = document.getElementById("pointer-layer");
    const arrow = document.getElementById("pointer-arrow");
    const ring = document.getElementById("pointer-ring");
    const caption = document.getElementById("pointer-caption");
    const target = document.getElementById("hero-cta");
    if (!hero || !layer || !arrow || !ring || !caption || !target) return;

    const h = hero.getBoundingClientRect();
    const t = target.getBoundingClientRect();
    const box = { x: t.left - h.left, y: t.top - h.top, w: t.width, h: t.height };

    // The synthetic mouse sits up and to the right of the headline.
    const narrow = h.width < 700;
    const start = narrow
      ? { x: h.width - 44, y: 20 }
      : { x: Math.min(h.width - 80, box.x + box.w + h.width * 0.42), y: 36 };
    // The arrow's tip lands inside the button, clear of its label.
    const end = { x: box.x + box.w * 0.8, y: box.y + box.h * 0.66 };

    // Ring: stroke centred on the 7 px inset, like the CAShapeLayer path.
    const pad = RING_INSET + RING_STROKE / 2;
    const radius = parseFloat(getComputedStyle(target).borderTopLeftRadius) || 10;
    Object.assign(ring.style, {
      width: `${box.w + pad * 2}px`,
      height: `${box.h + pad * 2}px`,
      transform: `translate(${box.x - pad}px, ${box.y - pad}px)`,
      borderRadius: `${radius + pad}px`,
    });
    caption.style.transform = `translate(${box.x - pad}px, ${box.y + box.h + pad + 8}px)`;

    const tip = (p) => `translate(${p.x - 3}px, ${p.y - 3}px)`; // tip is at (3, 3) in the path

    const fadeIn = { opacity: [0, 1] };
    const fadeOut = { opacity: [1, 0] };

    if (reduceMotion.matches) {
      arrow.style.transform = tip(end);
      [arrow, ring, caption].forEach((el) =>
        el.animate(fadeIn, { duration: 200, fill: "forwards" }));
      setTimeout(() => [arrow, ring, caption].forEach((el) =>
        el.animate(fadeOut, { duration: 300, fill: "forwards" })), HOLD_MS + 200);
      return;
    }

    const dx = end.x - start.x;
    const dy = end.y - start.y;
    const dist = Math.max(1, Math.hypot(dx, dy));
    const bow = Math.min(dist * 0.28, 220);
    const mid = { x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 };
    // Screen coordinates grow downward, so this sign bows the arc up and out, as on a Mac.
    const control = { x: mid.x + (dy / dist) * bow, y: mid.y - (dx / dist) * bow };

    const quad = (s) => ({
      x: (1 - s) ** 2 * start.x + 2 * (1 - s) * s * control.x + s ** 2 * end.x,
      y: (1 - s) ** 2 * start.y + 2 * (1 - s) * s * control.y + s ** 2 * end.y,
    });

    // Paced: keyframe offsets follow arc length, like calculationMode = .paced.
    const N = 48;
    const pts = [];
    const lens = [0];
    for (let i = 0; i <= N; i += 1) {
      pts.push(quad(i / N));
      if (i > 0) lens.push(lens[i - 1] + Math.hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y));
    }
    const total = lens[N] || 1;
    const frames = pts.map((p, i) => ({ transform: tip(p), offset: lens[i] / total }));

    arrow.style.opacity = "1";
    const flight = arrow.animate(frames, {
      duration: FLIGHT_MS,
      easing: "cubic-bezier(0.16, 0.9, 0.2, 1)",
      fill: "forwards",
    });
    [ring, caption].forEach((el) =>
      el.animate(fadeIn, { duration: 180, delay: FLIGHT_MS * 0.72, fill: "forwards" }));

    flight.finished.then(() => {
      setTimeout(() => [arrow, ring, caption].forEach((el) =>
        el.animate({ opacity: [1, 0] }, { duration: 300, fill: "forwards" })), HOLD_MS);
    }).catch(() => {});

    // A resize mid-demo would leave the ring around the wrong spot; just hide it.
    window.addEventListener("resize", () => {
      layer.style.visibility = "hidden";
    }, { once: true });
  }

  // ---------------------------------------------------------------------------
  // Film: autoplays muted only without Reduce Motion, has a visible pause button (WCAG 2.2.2),
  // and pauses while scrolled out of view unless the viewer paused it.
  // ---------------------------------------------------------------------------
  function setupFilm() {
    const video = document.getElementById("promo");
    const toggle = document.getElementById("promo-toggle");
    const label = document.getElementById("promo-toggle-label");
    if (!video || !toggle || !label) return;

    video.removeAttribute("controls");
    toggle.hidden = false;
    let userPaused = reduceMotion.matches;

    const render = () => {
      const paused = video.paused;
      toggle.dataset.paused = paused ? "true" : "false";
      label.textContent = paused ? "Play film" : "Pause film";
    };
    const tryPlay = () => {
      const p = video.play();
      if (p && typeof p.catch === "function") p.catch(() => render());
    };

    toggle.addEventListener("click", () => {
      if (video.paused) { userPaused = false; tryPlay(); } else { userPaused = true; video.pause(); }
    });
    video.addEventListener("play", render);
    video.addEventListener("pause", render);

    // Browsers refuse to start media in a hidden tab, so a page opened in the background tries
    // again when it becomes visible.
    let inView = !("IntersectionObserver" in window);
    const maybePlay = () => {
      if (inView && !userPaused && video.paused && document.visibilityState === "visible") tryPlay();
    };
    if ("IntersectionObserver" in window) {
      new IntersectionObserver((entries) => {
        entries.forEach((e) => {
          inView = e.isIntersecting;
          if (inView) maybePlay();
          else if (!video.paused) video.pause();
        });
      }, { threshold: 0.25 }).observe(video);
    }
    document.addEventListener("visibilitychange", maybePlay);
    maybePlay();
    render();
  }

  // ---------------------------------------------------------------------------
  // Vercel Web Analytics (no cookies) and Speed Insights, on the deployed site only, so a local
  // preview makes no requests to paths that do not exist there.
  // ---------------------------------------------------------------------------
  function setupAnalytics() {
    if (!/\.vercel\.app$/.test(location.hostname)) return;
    window.va = window.va || function () { (window.vaq = window.vaq || []).push(arguments); };
    window.si = window.si || function () { (window.siq = window.siq || []).push(arguments); };
    ["/_vercel/insights/script.js", "/_vercel/speed-insights/script.js"].forEach((src) => {
      const s = document.createElement("script");
      s.src = src;
      s.defer = true;
      document.body.appendChild(s);
    });
  }

  function start() {
    setupFilm();
    setupAnalytics();
    // Wait for layout to settle, and for the tab to be visible, so the one flight is seen.
    const go = () => {
      if (document.visibilityState === "visible") { setTimeout(pointOnce, 700); return; }
      const onVisible = () => {
        if (document.visibilityState !== "visible") return;
        document.removeEventListener("visibilitychange", onVisible);
        setTimeout(pointOnce, 700);
      };
      document.addEventListener("visibilitychange", onVisible);
    };
    if (document.readyState === "complete") go(); else window.addEventListener("load", go, { once: true });
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start);
  else start();
})();
