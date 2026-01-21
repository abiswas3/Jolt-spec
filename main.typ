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
#include "chapters/chap2.typ"

#codebox()[
```rust
#[jolt::provable(memory_size = 10240, max_trace_length = 65536)]
fn fib(n: u32) -> u128 {
    let a: u128 = 0;
    let mut b: u128 = 1;

    start_cycle_tracking("fib_loop"); // Use `start_cycle_tracking("{name}")` to start a cycle span
    b = a + b;
    end_cycle_tracking("fib_loop"); // Use `end_cycle_tracking("{name}")` to end a cycle span
    b
}
```


]

#bibliography("ref.bib", style: "association-for-computing-machinery", title: auto) 
