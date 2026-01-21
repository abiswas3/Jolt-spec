// CALLOUTS
#let callout(
  body,
  title: "Callout",
  icon: "a",
  fill: "white",
  stroke: "1pt",
) = block(
  fill: fill,
  radius: 6pt,
  inset: 12pt,
  spacing: 8pt,
  width: 100%,
  stroke: stroke
)[
  // Header
  #set text(weight: "bold")
    #icon #text()[#title]

  // Body
  #set text(weight: "regular")
    #body
]

#let warning(body) = callout(
  title: "Warning",
  icon: "⚠️",
  fill: rgb("#fff4e5"),
  stroke: rgb("#f59e0b"),
)[#body]

#let danger(body) = callout(
  title: "Danger",
  icon: "⚠️",
  fill: red.transparentize(60%),
  stroke: red,
)[#body]

// CALLOUTS END
//
#let citet(label) = cite(label, form: "prose")
#let citeauthor(label) = cite(label, form: "author")
#let citeyear(label) = cite(label, form: "year")
#let citep(label) = cite(label, form: "normal")

#let todo(body) = text(fill: red, weight: "bold")[#body]
