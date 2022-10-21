# Aesop

Aesop (Automated Extensible Search for Obvious Proofs) is a proof search tactic
for Lean 4. It is broadly similar to Isabelle's `auto`. In essence, Aesop works
like this:

- As with `simp`, you tag a (large) collection of definitions with the
  `@[aesop]` attribute, registering them as Aesop _rules_. Rules can be
  arbitrary tactics. We provide convenient ways to create common types of rules,
  e.g. rules which apply a lemma.
- Aesop takes these rules and tries to apply each of them to the initial goal.
  If a rule succeeds and generates subgoals, Aesop recursively applies the rules
  to these subgoals, building a _search tree_.
- The search tree is explored in a _best-first_ manner. You can mark rules as
  more or less likely to be useful. Based on this information, Aesop prioritises
  the goals in the search tree, visiting more promising goals before less
  promising ones.
- Before any rules are applied to a goal, it is _normalised_, using a special
  (customisable) set of _normalisation rules_. An important built-in
  normalisation rule runs `simp_all`, so your `@[simp]` lemmas are taken into
  account by Aesop.
- Rules can be marked as _safe_ to optimise Aesop's performance. A safe rule is
  applied eagerly and is never backtracked. For example, Aesop's built-in rules
  safely split a goal `P ∧ Q` into goals for `P` and `Q`. After this split, the
  original goal `P ∧ Q` is never revisited.
- Aesop provides a set of built-in rules which perform logical operations (e.g.
  case-split on hypotheses `P ∨ Q`) and some other straightforward deductions.
- Aesop uses indexing methods similar to those of `simp` and other Lean tactics.
  This means it should remain reasonably fast even with a large rule set.

Aesop should be suitable for two main use cases:

- General-purpose automation, where Aesop is used to dispatch 'trivial' goals.
  Once mathlib is ported to Lean 4 and we have registered many lemmas as Aesop
  rules, Aesop will hopefully serve as a much more powerful `simp`.
- Special-purpose automation, where specific Aesop rule sets are built to
  address a certain class of goals. Tactics such as `measurability`,
  `continuity` or `tidy`, which perform some sort of recursive search, can
  hopefully be replaced by Aesop rule sets.

I only occasionally update this README, so details may be out of date. If you
have questions, please create an issue or ping me (Jannis Limperg) on the [Lean
Zulip](https://leanprover.zulipchat.com). Pull requests are very welcome!

## Building

With [elan](https://github.com/leanprover/elan) installed, `lake build`
should suffice.

## Adding Aesop to Your Project

To use Aesop in a Lean 4 project, first add this package as a dependency. In
your `lakefile.lean`, add

```lean
require aesop from git "https://github.com/JLimperg/aesop"
```

You also need to make sure that your `lean-toolchain` file contains the same
version of Lean 4 as Aesop's, and that your versions of Aesop's dependencies
(currently only `std4`) match. We unfortunately can't support version ranges at
the moment.

Now the following test file should compile:

```lean
import Aesop

example : α → α :=
  by aesop
```

On Windows, you may get an error when you `import Aesop`. See [this issue](https://github.com/JLimperg/aesop/issues/28). As a workaround, you can
remove the line `precompileModules := true` from Aesop's `lakefile.lean`. This
will decrease Aesop's performance.

## Quickstart

To get you started, I'll explain Aesop's major concepts with a series of
examples. A more thorough, reference-style discussion of follows in the next
section.

We first define our own version of lists (so as not to clash with the standard
library) and an `append` function:

``` lean
inductive MyList (α : Type _)
  | nil
  | cons (hd : α) (tl : MyList α)

namespace MyList

protected def append : (_ _ : MyList α) → MyList α
  | nil, ys => ys
  | cons x xs, ys => cons x (MyList.append xs ys)

instance : Append (MyList α) :=
  ⟨MyList.append⟩
```

We also tell `simp` to unfold applications of `append`. `aesop` uses the default
simp set when it normalises a goal, so it will automatically pick up these rules
as well.

```lean
@[simp]
theorem nil_append : nil ++ xs = xs := rfl

@[simp]
theorem cons_append : cons x xs ++ ys = cons x (xs ++ ys) := rfl
```

Now we define the `NonEmpty` predicate on `MyList`:

``` lean
declare_aesop_rule_sets [MyList.NonEmpty]

@[aesop safe (rule_sets [MyList.NonEmpty]) [constructors, cases]]
inductive NonEmpty : MyList α → Prop
  | cons : NonEmpty (cons x xs)
```

Here we see the first Aesop features. The `declare_aesop_rule_sets` command is
used to, well, declare Aesop **rule sets**. These are collections of **rules**,
which roughly correspond to tactics. When Aesop searches for a proof, it
systematically applies each available rule, then recursively searches for proofs
of the subgoals generated by the rule, and so on. A goal is proved when Aesop
applies a rule that generates no subgoals.

The **`@[aesop]`** attribute adds two rules for `NonEmpty` to our new rule set:

- A **`constructors`** rule. This rule tries to apply each constructor of
  `NonEmpty` whenever a goal has target `NonEmpty _`.
- A **`cases`** rule. This rule searches for hypotheses `h : NonEmpty _` and
  performs case analysis on them (like the `cases` tactic).

`constructors` and `cases` are examples of **rule builders**, which are
functions that turn a declaration into a rule.

Both rules above are added as **safe** rules. When a safe rule succeeds on a
goal encountered during the proof search, it is applied and the goal is never
revisited thereafter. In other words, the search does not backtrack safe rules.
We will later see **unsafe** rules, which can backtrack.

With these rules, we can prove a theorem about `NonEmpty` and `append`:

``` lean
@[aesop safe apply]
theorem nonEmpty_append {xs : MyList α} ys :
    NonEmpty xs → NonEmpty (xs ++ ys) := by
  aesop (rule_sets [MyList.NonEmpty])
```

Here we call Aesop with the `MyList.NonEmpty` rule set, plus some default rule
sets which are implicitly enabled (but can be disabled). Aesop finds a proof by
introducing the hypothesis `h : NonEmpty xs`, performing case analysis on `h`
and applying the `NonEmpty.cons` constructor.

If you want to see how Aesop proves your goal (or more likely, why it doesn't
prove your goal or why it takes too long to do so), you can enable tracing:

``` lean
set_option trace.aesop.steps true
```

This makes Aesop print out the steps it takes while searching for a proof. There
are also other tracing options which autocompletion should show you if you type
`set_option trace.aesop`.

The `@[aesop]` attribute on `nonEmpty_append` adds this lemma as a safe rule to
the default rule set. For this rule we use the **`apply`** rule builder, which
generates a rule that tries to apply `nonEmpty_append` whenever the target is of
the form `NonEmpty (_ ++ _)`.

After adding `nonEmpty_append`, Aesop can now prove consequences of this lemma:

``` lean
example {α : Type u} {xs : MyList α} ys zs :
    NonEmpty xs → NonEmpty (xs ++ ys ++ zs) := by
  aesop
```

Next, we prove another simple theorem about `NonEmpty`:

``` lean
theorem nil_not_NonEmpty (xs : MyList α) : xs = nil → ¬ NonEmpty xs := by
  aesop (add unsafe 10% cases MyList, norm unfold Not)
    (rule_sets [MyList.NonEmpty])
```

Here, we add two rules in an **`add`** clause. These rules are not part of a
rule set but are added for this Aesop call only. They demonstrate two new
features:

- **Unsafe** rules are rules which can backtrack. Here we add `cases MyList` as
  an unsafe rule because when we perform `cases` on a hypothesis `xs : MyList
  α`, we get `hd : α` and `tl : MyList α`. If the rule was safe, we could easily
  get into an infinite loop where we call `cases` on `tl` again, and so on.
  Unsafe rules, by contrast, are applied 'in parallel', so while we might still
  end up exploring a proof attempt that performs `cases` 20 times, other
  possible rules will also be considered and will hopefully lead us down a more
  fruitful path.

  To prioritise these different proof attempts, every unsafe rules is annotated
  with a **success probability**, here 10%. This should be an estimate of how
  likely it is that the rule will to lead to a successful proof. This estimate
  is used to prioritise goals: the initial goal starts with a priority of 100%
  and whenever we apply an unsafe rule, the priority of its subgoals is the
  priority of its parent goal times the success probability of the applied rule.
  So applying our `cases MyList` rule repeatedly would give us goals with
  priority 10%, 1%, 0.1% etc. Of course, the success probability of a rule is
  only a ballpark figure; it is not supposed to be precise in any sense.

- **Norm** rules are yet another class of rules. They are used to normalise the
  goal before any other rules are applied. As part of this normalisation
  process, we run a variant of `simp_all` with the global `simp` set plus
  Aesop-specific simp lemmas. The **`unfold`** builder adds such an
  Aesop-specific simp lemma which unfolds the `Not` definition. (Aesop does not,
  in fact, need this rule to succeed.)

Here are some other examples where normalisation comes in handy:

``` lean
@[aesop norm]
theorem nil_append (xs : MyList α) : nil ++ xs = xs := rfl

@[aesop norm]
theorem cons_append (x : α) xs ys : cons x xs ++ ys = cons x (xs ++ ys) := rfl

@[aesop norm]
theorem append_nil {xs : MyList α} :
    xs ++ nil = xs := by
  induction xs <;> aesop

theorem append_assoc {xs ys zs : MyList α} :
    (xs ++ ys) ++ zs = xs ++ (ys ++ zs) := by
  induction xs <;> aesop
```

After we've added unfolding lemmas for `append`, Aesop can prove theorems about
this function more or less by itself. (For these examples, `simp` would already
suffice.) However, we still need to perform induction explicitly. This is a
deliberate design choice: while there are some techniques for automating
induction, they are complex and not entirely reliable, so I don't think it makes
sense to implement them in a system where users can easily perform induction
themselves.

More examples may be found in the `tests` folder of this repository.

## Reference

This section contains a systematic and fairly comprehensive account of how Aesop
operates.

### Rules

A rule is a tactic plus some associated metadata. Rules come in three flavours:

- **Normalisation rules** (keyword `norm`) must generate zero or one subgoal.
  (Zero means that the rule closed the goal). Each normalisation rule is
  associated with an integer **penalty** (default 1). Normalisation rules are
  applied in a fixpoint loop in order of penalty, lowest first. For rules with
  equal penalties, the order is unspecified. See below for details on
  the normalisation algorithm.

  Normalisation rules can also be simp lemmas. These are constructed with the
  `unfold` or `simp` builder. They are used by a special `simp` call during
  the normalisation process.

- **Safe rules** (keyword `safe`) are applied after normalisation but before any
  unsafe rules. When a safe rule is successfully applied to a goal, the goal
  becomes *inactive*, meaning no other rules are considered for it. Like
  normalisation rules, safe rules are associated with a penalty (default 1)
  which determines the order in which the rules are tried.

  Safe rules should be provability-preserving, meaning that if a goal is
  provable and we apply a safe rule to it, the generated subgoals should still
  be provable. This is a less precise notion than it may appear since
  what is provable depends on the entire Aesop rule set.

- **Unsafe rules** (keyword `unsafe`) are tried only if all available safe rules
  have failed on a goal. When an unsafe rule is applied to a goal, the goal is
  not marked as inactive, so other (unsafe) rules may be applied to it. These
  rule applications are considered independently until one of them proves the
  goal (or until we've exhausted all available rules and determine that the goal
  is not provable with the current rule set).

  Each unsafe rule has a **success probability** between 0% and 100%. These
  probabilities are used to determine the priority of a goal. The initial goal
  has priority 100% and whenever we apply an unsafe rule, the priorities of its
  subgoals are the priority of the rule's parent goal times the rule's success
  probability. Safe rules are treated as having 100% success probability.

Rules can also be **multi-rules**. These are rules which 'nondeterministically'
apply multiple tactics to the goal. Each of these tactics is then considered as
one possible way to solve the goal. For example, registering the constructors of
the `Or` type will generate a multi-rule that, given a goal with target `A ∨ B`,
generates one rule application with goal `A` and one with goal `B`.

### Search Tree

Aesop's central data structure is a search tree. This tree alternates between
two kinds of nodes:

- **Goal nodes**: these nodes store a goal, plus metadata relevant to the
  search. The parent and children of a goal node are rule application nodes. In
  particular, each goal node has a **priority** between 0% and 100%.
- **Rule application ('rapp') nodes**: these goals store a rule (plus metadata).
  The parent and children of a rapp node are goal nodes. When the search tree
  contains a rapp node with rule `r`, parent `p` and children `c₁, ..., cₙ`,
  this means that the tactic of rule `r` was applied to the goal of `p`,
  generating the subgoals of the `cᵢ`.

When a goal node has multiple child rapp nodes, we have a choice of how to solve
the goals. This makes the tree an AND-OR tree: to prove a rapp, *all* its child
goals must be proved; to prove a goal, *any* of its child rapps must be proved.

### Search

We start with a search tree containing a single goal node. This node's goal is
the goal which Aesop is supposed to solve. Then we perform the following steps
in a loop, stopping if (a) the root goal has been proved; (b) the root goal
becomes unprovable; or (c) one of Aesop's rule limits has been reached. (There
are configurable limits on, e.g., the total number of rules applied or the
search depth.)

- Pick the highest-priority active goal node `G`. Roughly speaking, a goal node
  is active if it is not proved and we haven't yet applied all possible rules to
  it.
- If the goal of `G` has not been normalised yet, normalise it. That means we
  run the following normalisation loop:
  - Run the normalisation rules with negative penalty (lowest penalty first). If
    any of these rules is successful, restart the normalisation loop with the
    goal produced by the rule.
  - Run `simp` on all hypotheses and the target, using the global simp set (i.e.
    lemmas tagged `@[simp]`) plus Aesop's `simp` rules.
  - Run the normalisation rules with positive penalty (lowest penalty first).
    If any of these rules is successful, restart the normalisation loop.

  The loop ends when all normalisation rules fail. It destructively updates
  the goal of `G` (and may prove it outright).
- If we haven't tried to apply the safe rules to the goal of `G` yet, try to
  apply each safe rule (lowest penalty first). As soon as a rule succeeds, add
  the corresponding rapp and child goals to the tree and mark `G` as inactive.
  The child goals receive the same priority as `G`.
- Otherwise there is at least one unsafe rule that hasn't been tried on `G` yet
  (or else `G` would have been inactive). Try the unsafe rule with the highest
  success probability and if it succeeds, add the corresponding rapp and child
  goals to the tree. The child goals receive the priority of `G` times the
  success probability of the applied rule.

A goal is unprovable if we have applied all possible rules to it and all
resulting child rapps are unprovable. A rapp is unprovable if any of its
subgoals is unprovable.

During the search, a goal or rapp can also become irrelevant, meaning its
provability has no impact on the success of the overall proof search.
More formally, irrelevance is characterised by the following conditions:

- A goal is irrelevant if its parent rapp is unprovable. (This means that a
  sibling of the goal is already unprovable, in which case we already know that
  the parent rapp will never be proved.)
- A rapp is irrelevant if its parent goal is proved. (This means that a sibling
  of the rapp is already proved, and we only need one proof.)
- A goal or rapp is irrelevant if any of its ancestors is irrelevant.

### Rule Builders

A **rule builder** is a metaprogram that turns a declaration or hypothesis into
an Aesop rule. Currently available builders are:

- **`apply`**: generates a rule which tries to apply the given declaration or
  hypothesis `x` to the target. The rule acts like the tactic `apply x`.
- **`forward`**: when applied to a declaration or hypothesis of type `A₁ → ...
  Aₙ → B`, generates a rule which looks for hypotheses `h₁ : A₁`, ..., `hₙ : Aₙ`
  in the goal and, if they are found, adds a new hypothesis `h : B`. As an
  example, consider the lemma `even_or_odd`:

  ```lean
  even_or_odd : ∀ (n : Nat), Even n ∨ Odd n
  ```

  Registering this as a forward rule will cause the goal

  ```lean
  n : Nat
  m : Nat
  ⊢ T
  ```

  to be transformed into this:

  ```lean
  n : Nat
  hn : Even n ∨ Odd n
  m : Nat
  hm : Even m ∨ Odd m
  ⊢ T
  ```

  The forward builder may also be given a list of *immediate names*:

  ```
  (forward (immediate := [n])) even_or_odd 
  ```

  The immediate names, here `n`, refer to the arguments of `even_or_odd`. When
  Aesop applies a forward rule with explicit immediate names, it only matches
  the corresponding arguments to hypotheses. (Here, `even_or_odd` has only one
  argument, so there is no difference.)

  When no immediate names are given, Aesop considers every argument immediate,
  except for instance arguments and dependent arguments (i.e. those that can be
  inferred from the types of later arguments).

  When a forward rule has been successfully applied, it will not be tried again
  when processing its subgoals (and their subgoals, etc.). Without this limit,
  many forward rules would be applied infinitely often.
- **`elim`**: works like `forward`, but after the rule has been applied,
  hypotheses that were used as immediate arguments are cleared. As the name
  suggests, this is useful when you want to eliminate a hypothesis. E.g. the
  rule
  ```
  @[aesop norm elim]
  theorem and_elim_right : α ∧ β → α := ...
  ```
  will cause the goal
  ```
  h₁ : (α ∧ β) ∧ γ
  h₂ : δ ∧ ε
  ```
  to be transformed into
  ```
  h₁ : α
  h₂ : δ
  ```

  Unlike with `forward` rules, when an `elim` rule is successfully applied, it
  may be applied again to the resulting subgoals (and their subgoals, etc.).
  There is less danger of infinite cycles because the original hypothesis is
  cleared.

  However, if the hypothesis or hypotheses to which the `elim` rule is applied
  have dependencies, they are not cleared. In this case, you'll probably get
  an infinite cycle. (TODO fix this.)
- **`constructors`**: when applied to an inductive type or structure `T`,
  generates a rule which tries to apply each constructor of `T` to the target.
  This is a multi-rule, so if multiple constructors apply, they are considered
  in parallel. If you use this constructor to build an unsafe rule, each
  constructor application receives the same success probability; if this is not
  what you want, add separate `apply` rules for the constructors.
- **`cases`**: when applied to an inductive type or structure `T`, generates a
  rule that performs case analysis on every hypothesis `h : T` in the context.
  The rule recurses into subgoals, so `cases Or` will generate 6 goals when
  applied to a goal with hypotheses `h₁ : A ∨ B ∨ C` and `h₂ : D ∨ E`. However,
  if `T` is a recursive type (e.g. `List`), we only perform case analysis once
  on each hypothesis. Otherwise we would loop infinitely.

  The `patterns` option can be used to apply the rule only on hypotheses of a
  certain shape. E.g. the rule `(cases (patterns := [Fin 0])) Fin` will perform
  case analysis only on hypotheses of type `Fin 0`. Patterns can contain
  underscores, e.g. `0 ≤ _`. Multiple patterns can be given (separated by
  commas); the rule is then applied whenever at least one of the patterns
  matches a hypothesis.
- **`simp`**: when applied to an equation `eq : A₁ → ... Aₙ → x = y`, registers
  `eq` as a simp lemma for the builtin simp pass during normalisation. As such,
  this builder can only build normalisation rules.
- **`unfold`**: when applied to a definition or `let` hypothesis `f`, registers
  `f` to be unfolded (i.e. replaced with its definition) by the builtin simp
  pass during normalisation. As such, this builder can only build normalisation
  rules.
- **`tactic`**: takes a tactic and directly turns it into a rule. The given
  declaration (the builder does not work for hypotheses) must have type `TacticM
  Unit`, `Aesop.SimpleRuleTac` or `Aesop.RuleTac`. The latter are Aesop data
  types which associate a tactic with additional metadata; using them may allow
  the rule to operate somewhat more efficiently.

  The builder may be given an option `uses_branch_state := <boolean>` (default
  true). This indicates whether the given tactic uses the branch state; see
  below.

  Rule tactics should not be 'no-ops': if a rule tactic is not applicable to a
  goal, it should fail rather than return the goal unchanged. All no-op rules
  waste time and no-op `norm` rules will send normalisation into an infinite
  loop.

  Normalisation rules may not assign metavariables (other than the goal
  metavariable) or introduce new metavariables (other than the new goal
  metavariable). This can be a problem because some Lean tactics, e.g. `cases`,
  do so even in cases where you probably would not expect them to. I'm afraid
  there is currently no good solution for this.
- **`default`**: The default builder. This is the builder used when you
  register a rule without specifying a builder, but you can also use it
  explicitly. Depending on the rule's phase, the default builder tries
  different builders, using the first one that works. These builders are:
  - For `safe` and `unsafe` rules: `constructors`, `tactic`, `apply`.
  - For `norm` rules: `constructors`, `tactic`, `simp`, `apply`.

### Rule Sets

Rule sets are declared with the command

``` lean
declare_aesop_rule_sets [r₁, ..., rₙ]
```

where the `rᵢ` are arbitrary names. To avoid clashes, pick names in the
namespace of your package.

Within a rule set, rules are identified by their name, builder and phase
(safe/unsafe/norm). This means you can add the same declaration as multiple
rules with different builders or in different phases, but not with different
priorities or different builder options (if the rule's builder has any options).

Rules can appear in multiple rule sets, but in this case you should make sure
that they have the same priority and use the same builder options. Otherwise,
Aesop will consider these rules the same and arbitrarily pick one.

### The `@[aesop]` Attribute

Declarations can be added to rule sets by annotating them with the `@[aesop]`
attribute.

#### Single Rule

In most cases, you'll want to add one rule for the declaration. The syntax for
this is

``` lean
@[aesop <phase>? <priority>? <builder>? <rule_sets>?]
```

where

- `<phase>` is `safe`, `norm` or `unsafe`. Cannot be omitted except under the
  conditions in the next bullet.

- `<priority>` is:
  - For `safe` and `norm` rules, an integer penalty. Can be omitted, in which
    case the penalty defaults to 1.
  - For `unsafe` rules, a percentage between 0% and 100%. Cannot be omitted.
    You may omit the `unsafe` phase specification when giving a percentage.

- `<builder>` is one of the builders given above. If you want to pass options to
  a builder, write it like this (with mandatory parentheses):

  ```text
  (tactic (uses_branch_state := true))
  ```

  If no builder is specified, the default builder for the given phase is used.

- `<rule_sets>` is a clause of the form

  ```text
  (rule_sets [r₁, ..., rₙ])
  ```

  where the `rᵢ` are declared rule sets. (Parentheses are mandatory.) The rule
  is added exactly to the specified rule sets. If this clause is omitted, it
  defaults to `(rule_sets [default])`.

#### Multiple Rules

It is occasionally useful to add multiple rules for a single declaration, e.g.
a `cases` and a `constructors` rule for the same inductive type. In this case,
you can write for example

``` lean
@[aesop unsafe [constructors 75%, cases 90%]]
inductive T ...

@[aesop apply [safe (rule_sets [A]), 70% (rule_sets [B])]]
def foo ...

@[aesop [80% apply, safe 5 (forward (immediate := x))]]
def bar (x : T) ...
```

In the first example, two unsafe rules for `T` are registered, one with success
probability 75% and one with 90%.

In the second example, two rules are registered for `foo`. Both use the `apply`
builder. The first, a `safe` rule with default penalty, is added to rule set
`A`. The second, an `unsafe` rule with 70% success probability, is added to
rule set `B`.

In the third example, two rules are registered for `bar`: an `unsafe` rule with
80% success probability using the `apply` builder and a `safe` rule with penalty
5 using the `forward` builder.

In general, the grammar for the `@[aesop]` attribute is

``` lean
attr      ::= @[aesop <rule_expr>]
            | @[aesop [<rule_expr,+>]]

rule_expr ::= feature
            | feature <rule_expr>
            | feature [<rule_expr,+>]
```

where `feature` is a phase, priority, builder or `rule_sets` clause. This
grammar yields one or more trees of features and each branch of these trees
specifies one rule. (A branch is a list of features.)

### Erasing Rules

There are two ways to erase rules. Usually it suffices to remove the `@[aesop]`
attribute:

``` lean
attribute [-aesop] foo
```

This will remove all rules associated with the declaration `foo` from all rule
sets.

When you want to remove only certain rules, you can use a command:

``` lean
erase_aesop_rules [safe apply foo, bar (rule_sets [A])]
```

This will remove:

- all safe rules for `foo` with the `apply` builder from all rule sets (but not
other, for example, unsafe rules or `forward` rules);
- all rules for `bar` from rule set `A`.

In general, the syntax is

``` lean
erase_aesop_rules [<rule_expr,+>]
```

i.e. rules are specified in the same way as for the `@[aesop]` attribute.
However, each rule must also specify the name of the declaration whose rules
should be erased. The `rule_expr` grammar is therefore extended such that a
`feature` can also be the name of a declaration.

Note that a rule added with one of the default builders (`safe_default`,
`norm_default`, `unsafe_default`) will be registered under the name of the
builder that is ultimately used, e.g. `apply` or `simp`. So if you want to erase
such a rule, you may have to specify that builder instead of the default
builder.

### The `aesop` Tactic

In its most basic form, you can call the Aesop tactic just by writing

``` lean
example : α → α := by
  aesop
```

This will use the rules in the `default` rule set (i.e. those added via the
attribute with no explicit rule set specified) and the rules in the `builtin`
rule set (i.e. those provided by Aesop itself).

The tactic's behaviour can also be customised with various options. A more
involved Aesop call might look like this:

``` text
aesop
  (add safe foo, 10% cases Or, safe cases Empty)
  (erase A [cases, constructors], baz)
  (rule_sets [A, B])
  (options := { maxRuleApplicationDepth := 10 })
```

Here we add some rules with an `add` clause, erase other rules with an `erase`
clause, limit the used rule sets and set some options. Each of these clauses
is discussed in more detail below.

#### Adding Rules

Rules can be added to an Aesop call with an `add` clause. This won't affect any
declared rule sets. The syntax of the `add` clause is

``` text
(add <rule_expr,+>)
```

i.e. rules can be specified in the same way as for the `@[aesop]` attribute.
As with the `erase_aesop_rules` command, each rule must specify the name of
declaration from which the rule should be built; for example

``` text
(add safe [foo 1, bar 5])
```

will add the declaration `foo` as a safe rule with penalty 1 and `bar` as a safe
rule with penalty 5.

The rule names can also refer to hypotheses in the goal context, but not all
builders support this.

#### Erasing Rules

Rules can be removed from an Aesop call with an `erase` clause. Again, this
affects only the current Aesop call and not the declared rule sets. The syntax
of the `erase` clause is

``` text
(erase <rule_expr,+>)
```

and it works exactly like the `erase_aesop_rules` command.

#### Selecting Rule Sets

By default, Aesop uses the `default` and `builtin` rule sets. A `rule_sets`
clause can be given to include additional rule sets, e.g.

``` text
(rule_sets [A, B])
```

This will use rule sets `A`, `B`, `default` and `builtin`. Rule sets can also
be disabled with `rule_sets [-default, -builtin]`.

#### Setting Options

Various options can be set with an `options` clause, whose syntax is:

``` text
(options := <term>)
```

The term is an arbitrary Lean expression of type `Aesop.Options`; see there for
details. A notable option is `strategy`, which is one of `.bestFirst`,
`.depthFirst` and `.breadthFirst` and instructs Aesop to use the corresponding
search strategy. Best-first is the default.

Similarly, options for the builtin norm simp call can be set with

``` text
(simp_options := <term>)
```

The term has type `Aesop.Simp.Config`; see there for details. The `useHyps`
option may be particularly useful: when `true` (the default), norm simp behaves
like the `simp_all` tactic; when `false`, norm simp behaves like
`simp (config := { contextual := true }) at *`.

### Builtin Rules

The set of builtin rules (those in the `builtin` rule set) is currently quite
unstable, so for now I won't document them in detail. See
`Aesop/BuiltinRules.lean` and `Aesop/BuiltinRules/*.lean`

### Tracing

To see how Aesop proves a goal -- or why it doesn't prove a goal, or why it's
slow to prove a goal -- it is useful to see what it's doing. To that end, you
can enable various tracing options. These use the usual syntax, e.g.

``` lean
set_option trace.aesop.steps true
```

The main options are:

- `trace.aesop.steps`: print a step-by-step log of which goals Aesop tried to
  solve, which rules it tried to apply (successfully or unsuccessfully), etc.
  You can customise the output by setting various sub-options, e.g.
  `trace.aesop.steps.normalization` will show which normalisation rules were
  applied. When you autocomplete `set_option trace.aesop.steps.`, you should
  get a full list of available sub-options.
- `trace.aesop.ruleSet`: print the rule set used for an Aesop call.
- `trace.aesop.profile`: print some information about where Aesop spent its
  time.
- `trace.aesop.proof`: if Aesop is successful, print the proof that was
  generated (as a Lean term).

### Checking Internal Invariants

If you encounter behaviour that looks like an internal error in Aesop, it may
help to set the option `aesop.check.all` (or the more fine-grained
`aesop.check.*` options). This makes Aesop check various invariants while the
tactic is running. These checks are somewhat expensive, so remember to unset the
option after you've reported the bug.

### Advanced Features of the Search Algorithm

#### Branch State

TODO

#### Metavariables

TODO
