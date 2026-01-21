#import "preamble.typ": *
#bib_state.update(none)
#import "template.typ": *
#import "commands.typ": * 

#show: template.with(
  title: "Jolt Formal Specification",
  authors: ("Ari", "Quang Dao", "Rose Silver", "Justin Thaler",),
)


#include "chapters/chap1.typ"
#include "chapters/chap2.typ"

#bibliography("ref.bib", style: "association-for-computing-machinery", title: auto) 
