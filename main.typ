#import "preamble.typ": *
#bib_state.update(none)
#import "template.typ": *
#import "commands.typ": * 

#show: template.with(
  title: "Jolt Formal Specification",
  authors: ("Ari", "Quang Dao", "Rose Silver", "Justin Thaler",),
)

// #import "code_template.typ": conf
// #show: conf.with(cols: 92)

#include "chapters/chap1.typ"
// #include "chapters/chap2.typ"
#include "chapters/compilations.typ"



#bibliography("ref.bib", style: "association-for-computing-machinery", title: auto) 
