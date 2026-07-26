// The session's mode / model / effort pickers — one bottom sheet, mounted by
// exactly ONE line in ChatSessionScreen's header.
//
// THE LAW THIS FILE EXISTS TO KEEP (ratified call #5): a session has two model
// facts and they are not the same fact.
//
//   • the CHOSEN model  — `choices.modelChoice`, the user's persisted REQUEST.
//     It may be an alias, it may not have taken effect yet, and it is the only
//     one the picker writes.
//   • the OBSERVED model — `state.model` off the system/init frame, what the
//     engine ACTUALLY answered with. This is the first consumer that field has
//     ever had on mobile. It is fact, it is read-only, and it is empty until a
//     turn streams.
//
// Rendering the chosen one alone would be the lie the Studio's observed-model
// row (scc-w5) was built to stop: you ask for "opus", the server resolves
// something else, and the UI keeps telling you what you asked for. So when the
// two disagree the sheet says so, in those words.
//
// The vocabulary is DISCOVERED (charter D27, GET /v1/capabilities?chat=1),
// never invented. Three honest degrades, three different screens:
//   • no block at all (old server / tier none) → say the server advertises
//     nothing, offer nothing.
//   • provider present but all-empty (codex, today) → say this provider
//     advertises nothing, offer nothing. NOT a dead picker with fake rows.
//   • provider absent from a block that exists → same, named.
//
// bypassPermissions never appears: the server's own claude mode list omits it
// (charter D22 — the arm ceremony is a Studio-only affordance and the phone is
// correctly unreachable), so honoring discovery IS honoring D22.
import { memo, useMemo } from 'react'
import { Modal, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native'

import type { ChatCapabilities, ChatProviderCaps } from '../api/chat'
import type { SessionChoices } from './sessionStore'
import { haptic } from '../ui/haptics'
import type { Theme } from '../ui/theme'

/** Which picker row a value belongs to — also the SessionChoices key it
 * writes, so there is no second mapping to drift. */
export type PickerKind = 'mode' | 'modelChoice' | 'effortChoice'

/** What the sheet can offer for one provider, resolved from discovery. */
export interface PickerVocabulary {
  modes: string[]
  models: string[]
  efforts: string[]
  /** Set when there is nothing to offer — the honest line to render INSTEAD of
   * pickers. undefined means at least one row has options. */
  degraded?: string
}

/** Resolves the offerable vocabulary for a provider (PURE).
 *
 * `caps === undefined` and `caps.providers[provider]` being all-empty are
 * different facts with different copy — collapsing them into one "no pickers"
 * message would hide which side is silent. A session whose provider has not
 * loaded yet ('') degrades quietly rather than guessing "claude". */
export function pickerVocabulary(
  caps: ChatCapabilities | undefined,
  provider: string,
): PickerVocabulary {
  const empty = { modes: [], models: [], efforts: [] }
  if (provider === '') {
    return { ...empty, degraded: 'Loading this session…' }
  }
  if (caps === undefined) {
    return { ...empty, degraded: 'This Barkpark does not advertise picker options.' }
  }
  const p: ChatProviderCaps | undefined = caps.providers[provider]
  if (p === undefined) {
    return { ...empty, degraded: `This Barkpark advertises no options for ${provider}.` }
  }
  const v: PickerVocabulary = {
    modes: p.modes ?? [],
    models: p.models ?? [],
    efforts: p.efforts ?? [],
  }
  if (v.modes.length === 0 && v.models.length === 0 && v.efforts.length === 0) {
    return { ...v, degraded: `${provider} advertises no mode, model or effort options.` }
  }
  return v
}

/** The observed-model line, or undefined when there is nothing honest to add
 * (PURE — the whole ratified-call-#5 rule in one function).
 *
 * Silent when the model has not been observed yet (no turn has streamed) and
 * silent when observation matches the request. It speaks ONLY on a real
 * disagreement, which is the only case where showing the request alone would
 * mislead. A blank request with a live observation still speaks: "answering
 * with X" is worth knowing even when nothing was asked for. */
export function observedModelNote(
  observed: string,
  chosen: string,
): { text: string; disagrees: boolean } | undefined {
  const obs = observed.trim()
  if (obs === '') return undefined
  const req = chosen.trim()
  if (req === '') return { text: `answering with ${obs}`, disagrees: false }
  if (req === obs) return { text: `answering with ${obs}`, disagrees: false }
  return { text: `you asked for ${req} — answering with ${obs}`, disagrees: true }
}

/** Effort has no observed counterpart and no live-steer verb: there is no
 * set_effort control frame (the four control subtypes are closed), so a change
 * lands on the next resume. Studio prints this line; so do we — one behavior,
 * one sentence, everywhere. */
export const EFFORT_HONESTY = 'Effort applies from the next resume.'

interface PickerSheetProps {
  visible: boolean
  onClose: () => void
  theme: Theme
  /** Discovered vocabulary; undefined when the server advertises none. */
  capabilities: ChatCapabilities | undefined
  choices: SessionChoices
  /** The OBSERVED model off system/init (reducer state.model) — read-only. */
  observedModel: string
  onPick: (kind: PickerKind, value: string) => void
  /** Dismiss this session (charter D28). Present here because this sheet IS
   * the session-options surface and Studio puts archive in exactly the same
   * place (the kebab) — which is also what makes the "archiving the session
   * you are looking at pops you out" leg reachable at all on the phone.
   * Undefined when the owner offers no archive route. */
  onArchive?: () => void
}

/** The sheet. Mounted unconditionally by one line in ChatSessionScreen; the
 * Modal itself owns visibility, so the header stays a single expression. */
export const PickerSheet = memo(function PickerSheet({
  visible,
  onClose,
  theme,
  capabilities,
  choices,
  observedModel,
  onPick,
  onArchive,
}: PickerSheetProps): React.ReactElement {
  const vocab = useMemo(
    () => pickerVocabulary(capabilities, choices.provider),
    [capabilities, choices.provider],
  )
  const note = observedModelNote(observedModel, choices.modelChoice)

  return (
    <Modal
      visible={visible}
      transparent
      animationType="slide"
      onRequestClose={onClose}
    >
      <Pressable
        accessibilityRole="button"
        accessibilityLabel="Close the session pickers"
        style={styles.scrim}
        onPress={onClose}
      />
      <View style={[styles.sheet, { backgroundColor: theme.surface, borderColor: theme.border }]}>
        <View style={styles.grabber}>
          <View style={[styles.grabberBar, { backgroundColor: theme.border }]} />
        </View>
        <ScrollView contentContainerStyle={styles.sheetBody}>
          {vocab.degraded !== undefined ? (
            <Text style={[styles.degraded, { color: theme.textMuted }]}>{vocab.degraded}</Text>
          ) : (
            <>
              <PickerRow
                label="Mode"
                kind="mode"
                options={vocab.modes}
                selected={choices.mode}
                theme={theme}
                onPick={onPick}
              />
              <PickerRow
                label="Model"
                kind="modelChoice"
                options={vocab.models}
                selected={choices.modelChoice}
                theme={theme}
                onPick={onPick}
              />
              {note !== undefined && (
                <Text
                  style={[
                    styles.note,
                    { color: note.disagrees ? theme.warn : theme.textMuted },
                  ]}
                >
                  {note.text}
                </Text>
              )}
              <PickerRow
                label="Effort"
                kind="effortChoice"
                options={vocab.efforts}
                selected={choices.effortChoice}
                theme={theme}
                onPick={onPick}
              />
              {vocab.efforts.length > 0 && (
                <Text style={[styles.note, { color: theme.textMuted }]}>{EFFORT_HONESTY}</Text>
              )}
            </>
          )}
          {onArchive !== undefined && (
            <Pressable
              accessibilityRole="button"
              accessibilityLabel="Archive this session"
              onPress={onArchive}
              style={[styles.archiveRow, { borderTopColor: theme.border }]}
            >
              <Text style={[styles.archiveText, { color: theme.danger }]}>Archive session</Text>
              {/* Dismissal, not deletion, and not a status change — say so
                  rather than let "archive" read as either. */}
              <Text style={[styles.note, { color: theme.textMuted }]}>
                Moves it to the archived shelf. Nothing is deleted and the
                session keeps running.
              </Text>
            </Pressable>
          )}
        </ScrollView>
      </View>
    </Modal>
  )
})

/** One labelled row of chips. An empty option list renders NOTHING — a row of
 * no chips reads as a broken control, and "this provider has none" is already
 * said once at the sheet level. */
function PickerRow({
  label,
  kind,
  options,
  selected,
  theme,
  onPick,
}: {
  label: string
  kind: PickerKind
  options: string[]
  selected: string
  theme: Theme
  onPick: (kind: PickerKind, value: string) => void
}): React.ReactElement | null {
  if (options.length === 0) return null
  return (
    <View style={styles.row}>
      <Text style={[styles.rowLabel, { color: theme.textMuted }]}>{label}</Text>
      <View style={styles.chips}>
        {options.map((option) => {
          const on = option === selected
          return (
            <Pressable
              key={option}
              accessibilityRole="button"
              accessibilityState={{ selected: on }}
              accessibilityLabel={`${label}: ${option}`}
              onPress={() => {
                haptic('disclosureToggle')
                onPick(kind, option)
              }}
              style={[
                styles.chip,
                {
                  backgroundColor: on ? theme.accent : 'transparent',
                  borderColor: on ? theme.accent : theme.border,
                },
              ]}
            >
              <Text style={[styles.chipText, { color: on ? theme.accentText : theme.text }]}>
                {option}
              </Text>
            </Pressable>
          )
        })}
      </View>
    </View>
  )
}

const styles = StyleSheet.create({
  scrim: { flex: 1, backgroundColor: 'rgba(0,0,0,0.35)' },
  sheet: {
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopLeftRadius: 16,
    borderTopRightRadius: 16,
    maxHeight: '70%',
  },
  grabber: { alignItems: 'center', paddingTop: 8, paddingBottom: 4 },
  grabberBar: { width: 36, height: 4, borderRadius: 2 },
  sheetBody: { paddingHorizontal: 20, paddingTop: 8, paddingBottom: 32, gap: 18 },
  row: { gap: 8 },
  rowLabel: { fontSize: 12, fontWeight: '700', letterSpacing: 0.6, textTransform: 'uppercase' },
  chips: { flexDirection: 'row', flexWrap: 'wrap', gap: 8 },
  chip: { borderWidth: 1, borderRadius: 999, paddingHorizontal: 12, paddingVertical: 7 },
  chipText: { fontSize: 14, fontWeight: '600' },
  note: { fontSize: 13, lineHeight: 18 },
  archiveRow: { borderTopWidth: StyleSheet.hairlineWidth, paddingTop: 16, gap: 4 },
  archiveText: { fontSize: 15, fontWeight: '600' },
  degraded: { fontSize: 14, lineHeight: 20, paddingVertical: 12 },
})
