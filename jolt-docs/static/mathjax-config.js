window.MathJax = {
  tex: {
    inlineMath: [["$", "$"]],
    displayMath: [["$$", "$$"]],
    processEscapes: true,
    tags: "ams",
    macros: {
      // =====================================================
      // Jolt-specific LaTeX macros
      // Add custom macros here. They are available on every
      // page where MathJax is loaded.
      //
      // Syntax:
      //   name: "expansion"                    — no arguments
      //   name: ["expansion with #1", 1]       — 1 argument
      //   name: ["expansion with #1 and #2", 2] — 2 arguments
      //
      // Examples:
      FF: "\\mathbb{F}",
      bit: "\\{0,1\\}",
      hypercube: ["\\{0,1\\}^{\\log_2 #1}", 1],
      FFlog: ["\\mathbb{F}^{\\log_2 #1}", 1],
      bin: ["\\langle #1 \\rangle_2", 1],
      mle: ["{\\color{purple}{#1}}", 1],
      range: ["\\{0, \\ldots, #1 - 1\\}", 1],
      X: ["{\\color{teal}{#1}}", 1],
      eqpoly: ["\\mle{\\textsf{eq}}(#1, #2)", 2],
      rr: ["{\\color{red}{r_{\\text{#1}}}}", 1],
      // =====================================================
    },
  },
  options: {
    skipHtmlTags: ["script", "noscript", "style", "textarea", "pre", "code"],
  },
};
