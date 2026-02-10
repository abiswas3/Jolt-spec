window.MathJax = {
  tex: {
    inlineMath: [["$", "$"]],
    displayMath: [["$$", "$$"]],
    processEscapes: true,
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
      //   NN: "\\mathbb{N}",
      //   poly: ["\\mathrm{poly}(#1)", 1],
      //   com: ["\\mathsf{com}(#1)", 1],
      //   ip: ["\\langle #1, #2 \\rangle", 2],
      // =====================================================
    },
  },
  options: {
    skipHtmlTags: ["script", "noscript", "style", "textarea", "pre", "code"],
  },
};
