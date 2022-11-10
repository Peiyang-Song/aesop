/-
Copyright (c) 2022 Jannis Limperg. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jannis Limperg
-/

import Aesop.Check
import Aesop.Frontend.Attribute
import Aesop.Options
import Aesop.RuleSet
import Aesop.Search.Expansion
import Aesop.Search.ExpandSafePrefix
import Aesop.Search.Queue
import Aesop.Tree
import Aesop.Util

open Lean
open Lean.Elab.Tactic (liftMetaTacticAux TacticM)
open Lean.Parser.Tactic (tacticSeq)
open Lean.Meta

namespace Aesop

variable [Aesop.Queue Q]

partial def nextActiveGoal : SearchM Q GoalRef := do
  let some gref ← popGoal?
    | throwError "aesop/expandNextGoal: internal error: no active goals left"
  if ! (← (← gref.get).isActive) then
    aesop_trace[steps] "Skipping inactive goal {(← gref.get).id}."
    nextActiveGoal
  else
    return gref

def expandNextGoal : SearchM Q Unit := do
  let gref ← nextActiveGoal
  aesop_trace[steps] "Expanding {← (← gref.get).toMessageData (← TraceModifiers.get)}"
  let maxRappDepth := (← read).options.maxRuleApplicationDepth
  if maxRappDepth != 0 && (← gref.get).depth >= maxRappDepth then
    aesop_trace[steps] "Skipping goal since it is beyond the maximum rule application depth ({maxRappDepth})."
    gref.markForcedUnprovable
    setMaxRuleApplicationDepthReached
    return
  expandGoal gref
  let currentIteration ← getIteration
  gref.modify λ g => g.setLastExpandedInIteration currentIteration
  if ← (← gref.get).isActive then
    enqueueGoals #[gref]

def checkGoalLimit : SearchM Q (Option MessageData) := do
  let maxGoals := (← read).options.maxGoals
  let currentGoals := (← getTree).numGoals
  if maxGoals != 0 && currentGoals >= maxGoals then
    return m!"maximum number of goals ({maxGoals}) reached. Set the 'maxGoals' option to increase the limit."
  return none

def checkRappLimit : SearchM Q (Option MessageData) := do
  let maxRapps := (← read).options.maxRuleApplications
  let currentRapps := (← getTree).numRapps
  if maxRapps != 0 && currentRapps >= maxRapps then
    return m!"maximum number of rule applications ({maxRapps}) reached. Set the 'maxRuleApplications' option to increase the limit."
  return none

def checkRootUnprovable : SearchM Q (Option MessageData) := do
  let root := (← getTree).root
  if (← root.get).state.isUnprovable then
    let msg :=
      if ← wasMaxRuleApplicationDepthReached then
        m!"failed to prove the goal. Some goals were not explored because the maximum rule application depth ({(← read).options.maxRuleApplicationDepth}) was reached. Set option 'maxRuleApplicationDepth' to increase the limit."
      else
        m!"failed to prove the goal after exhaustive search."
    return msg
  return none

def getProof? : SearchM Q (Option Expr) := do
  let (some proof) ← getExprMVarAssignment? (← read).rootGoalMVar
    | return none
  instantiateMVars proof

private def withPPAnalyze [Monad m] [MonadWithOptions m] (x : m α) : m α :=
  withOptions (·.setBool `pp.analyze true) x

def finalizeProof : SearchM Q Unit := do
  aesop_trace[steps] "Root node is proven. Linking proofs."
  (← read).rootGoalMVar.withContext do
    extractProof
    let (some proof) ← getProof? | throwError
      "aesop: internal error: root goal is proven but its metavariable is not assigned"
    if proof.hasExprMVar then throwError
      m!"aesop: internal error: extracted proof has metavariables." ++ MessageData.node #[
        m!"Proof: {proof}",
        m!"Unassigned metavariables: {(← getMVarsNoDelayed proof).map (·.name)}"
      ]
    aesop_trace[proof] do
      withPPAnalyze do
        aesop_trace![proof] "Final proof:{indentExpr proof}"

open Lean.Elab.Tactic in
def checkScript (script : TSyntax ``tacticSeq) : SearchM Q Unit := do
  let initialGoals := (← read).initialGoals
  let go : TacticM Unit := do
    let goal ← getMainGoal
    setGoals [goal]
    evalTactic script
    unless (← getUnsolvedGoals).isEmpty do
      throwError "script executed successfully but did not solve the main goal"
  try
    discard $ show MetaM _ from withoutModifyingState $ do
      initialGoals.forM eraseExprMVarAssignment
      go.run { elaborator := .anonymous, recover := false }
        |>.run { goals := initialGoals.toList } |>.run
  catch e => throwError
    "{Check.script.name}: error while executing generated script:{indentD e.toMessageData}"

def traceScript : SearchM Q Unit := do
  let ctx ← read
  let doCheck ← Check.script.isEnabled
  if ! ctx.options.traceScript && ! doCheck then
    return
  let script? ←
    try
      let script ← (← getRootMVarCluster).extractScript
      let script ← script.render ctx.initialGoals
      let script ← `(tacticSeq| $script:tactic*)
      if ctx.options.traceScript then
        withPPAnalyze do
          logInfo m!"Try this:\n{script}"
      pure $ some script
    catch e =>
      logError m!"aesop: error while generating tactic script:{indentD e.toMessageData}"
      pure none
  if doCheck then
    if let (some script) := script? then
      checkScript script

def finishIfProven : SearchM Q Bool := do
  unless (← (← getRootMVarCluster).get).state.isProven do
    return false
  finalizeProof
  traceScript
  -- `traceScript` needs to run after `finalizeProof` because in `checkScript`
  -- we assume that all the intermediate mvars are available in the current
  -- `MetavarContext`.
  return true

def traceFinalTree : SearchM Q Unit := do
  aesop_trace[finalTree] do
    let treeMsg ←
      (← (← getRootGoal).get).treeToMessageData (← TraceModifiers.get)
    aesop_trace![finalTree] "Final search tree:{indentD treeMsg}"

-- When we hit a non-fatal error (i.e. the search terminates without a proof
-- because the root goal is unprovable or because we hit a search limit), we
-- usually:
--
-- - Expand all safe rules as much as possible, starting from the root node,
--   until we hit an unsafe rule. We call this the safe prefix.
-- - Extract the proof term for the safe prefix and report the remaining goals.
--
-- The first step is necessary because a goal can become unprovable due to a
-- sibling being unprovable, without the goal ever being expanded. So if we did
-- not expand the safe rules after the fact, the tactic's output would be
-- sensitive to minor changes in, e.g., rule priority.
def handleNonfatalError (err : MessageData) : SearchM Q (Array MVarId) := do
  aesop_trace[steps] "Search terminated unsuccessfully."
  let err := m!"aesop: {err}"
  let opts := (← read).options
  if opts.terminal then
    throwError err
  if opts.warnOnNonterminal then
    logWarning err
  expandSafePrefix
  let goals ← extractSafePrefix
  aesop_trace[proof] do
    let proof? ← getProof?
    (← read).rootGoalMVar.withContext do
      match proof? with
      | some proof => aesop_trace![proof] "Final proof:{indentExpr proof}"
      | none => aesop_trace![proof] "Final proof: <none>"
  traceFinalTree
  return goals

def handleFatalError (e : Exception) : SearchM Q α := do
  traceFinalTree
  throw e

partial def searchLoop : SearchM Q (Array MVarId) :=
  withIncRecDepth do
    aesop_trace[steps] "=== Search loop iteration {← getIteration}"
    if let (some err) ← checkRootUnprovable then
      return (← handleNonfatalError err)
    if ← finishIfProven then
      return #[]
    if let (some err) ← checkGoalLimit then
      return (← handleNonfatalError err)
    if let (some err) ← checkRappLimit then
      return (← handleNonfatalError err)
    expandNextGoal
    aesop_trace[stepsTree] "Current search tree:{indentD $ ← (← (← getRootGoal).get).treeToMessageData (← TraceModifiers.get)}"
    aesop_trace[stepsActiveGoalQueue] "Current active goals:{← formatQueue}"
    checkInvariantsIfEnabled
    incrementIteration
    searchLoop

/--
The `goals` should be the current goals (as reported by `getGoals`). If you
don't use Aesop's `traceScript` option, `goals` may also contain just the
current main goal (as reported by `getMainGoal`).
-/
def search (goals : Array MVarId) (ruleSet? : Option RuleSet := none)
     (options : Aesop.Options := {}) (simpConfig : Aesop.SimpConfig := {})
     (profile : Profile := {}) :
     MetaM (Array MVarId × Profile) := do
  if h : 0 < goals.size then
    goals[0].checkNotAssigned `aesop
    let ruleSet ←
      match ruleSet? with
      | none => Frontend.getDefaultRuleSet
      | some ruleSet => pure ruleSet
    let ⟨Q, _⟩ := options.queue
    let (goals, state, _) ← SearchM.run ruleSet options simpConfig goals profile do
      show SearchM Q _ from
      try searchLoop
      catch e => handleFatalError e
      finally freeTree
    return (goals, state.profile)
  else
    throwError "aesop: no goals to be solved"

end Aesop
