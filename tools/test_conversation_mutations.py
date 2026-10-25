#!/usr/bin/env python3
"""Prove the consent completeness property rejects production mutations.

Run only against an expendable copy: python3 tools/test_conversation_mutations.py /tmp/ap-.../repo
The caller supplies isolated HOME, DB and test paths, just as for swift test.
"""
import pathlib
import subprocess
import sys


def main():
    repo = pathlib.Path(sys.argv[1]).resolve()
    temporary = pathlib.Path('/tmp').resolve()
    if temporary not in repo.parents or (repo / '.git').exists():
        raise SystemExit('An expendable temporary copy without .git is required.')
    mutations = [
        ('decisive-field', 'Sources/Outbound/ConversationRequestPresentation.swift',
         'nativeFacts: details.keys.sorted().map {',
         'nativeFacts: details.keys.sorted().filter { $0 != "isBlocking" }.map {'),
        ('rendered-reference', 'Sources/Shell/ConversationDecisionButton.swift',
         'button.title = choice.reference + " " + choice.label',
         'button.title = choice.label'),
        ('choice-scope', 'Sources/Outbound/ConversationRequestPresentation.swift',
         'let scope = readable(payload)',
         'let scope = readable(payload.merging(["updatedPermissions": [["type": "addRules", "destination": "invented-wrong-scope"]]]) { _, wrong in wrong })'),
    ]
    mutations.append(('accessible-name-bypass', 'Sources/Shell/ConversationAccessibility.swift',
                      'name.inRequest(requestReference).assign(to: button); button.isEnabled = enabled\n    if let expanded',
                      'button.setAccessibilityLabel(title); button.cell?.setAccessibilityLabel(title); button.isEnabled = enabled\n    if let expanded'))
    mutations.append(('request-reference', 'Sources/Shell/ConversationApprovalView.swift',
                      '.environment(\\.conversationRequestReference, reference)',
                      '.environment(\\.conversationRequestReference, "")'))
    mutations.append(('visible-text', 'Sources/Shell/ConversationQuestions.swift',
                      'let text = state.values[field.id] ?? ""',
                      'let text = (state.values[field.id] ?? "") + "invented-hidden-value"'))
    mutations.append(('question-grants', 'Sources/Outbound/ConversationApprovals.swift',
                      'if !isQuestion, request["suppress_always_allow_rule"]',
                      'if request["suppress_always_allow_rule"]'))
    mutations.append(('empty-properties', 'Sources/Outbound/ConversationRequestPresentation.swift',
                      'NSDictionary(dictionary: schema).isEqual(to: fixed)',
                      '(schema["properties"] as? [String: Any])?.isEmpty == true'))
    for name, relative, before, after in mutations:
        path = repo / relative
        original = path.read_bytes()
        text = original.decode()
        if text.count(before) != 1:
            raise SystemExit(f'{name}: mutation anchor must occur exactly once')
        try:
            path.write_text(text.replace(before, after))
            selected = {
                'visible-text': 'ConversationSelectionTests/testVisibleTextAndNativeReplies',
                'question-grants': 'ConversationAcceptingPathsTests/testQuestionGrantWitnessesHaveOnlySubmitAndDecline|ConversationAcceptingPathsTests/testEveryEnabledButtonOverWholeInventoryPreservesAcceptingContract',
                'empty-properties': 'ConversationAcceptingPathsTests/testIndirectFieldWitnessesRefuseOnce|ConversationAcceptingPathsTests/testEveryEnabledButtonOverWholeInventoryPreservesAcceptingContract',
            }.get(name, 'ConversationDecisionTests/testCompletenessMutationWitnesses|ConversationAccessibilityTests/testAccessibilityMutationWitness|ConversationAccessibilityTests/testWholePageRequestIdentityMutationWitness')
            result = subprocess.run(['swift', 'test', '--jobs', '1', '--filter', selected],
                                    cwd=repo, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            (repo.parent / f'mutation-{name}.log').write_text(result.stdout)
            if result.returncode == 0 or ('XCTAssert' not in result.stdout and 'failed -' not in result.stdout) or 'Build complete!' not in result.stdout:
                raise SystemExit(f'{name}: property did not reject the built mutation ({result.returncode})')
            print(f'{name}: property rejected mutation, exit {result.returncode}', flush=True)
        finally:
            path.write_bytes(original)
    result = subprocess.run(['swift', 'test', '--jobs', '1', '--filter',
                             'ConversationDecisionTests/testCompletenessMutationWitnesses|ConversationAccessibilityTests/testAccessibilityMutationWitness|ConversationAccessibilityTests/testWholePageRequestIdentityMutationWitness|ConversationSelectionTests|ConversationAcceptingPathsTests'], cwd=repo)
    if result.returncode:
        raise SystemExit('Restored production must pass the same property')
    print('All eight mutations rejected; restored production passed.')


if __name__ == '__main__':
    main()
