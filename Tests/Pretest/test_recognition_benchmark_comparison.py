import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("comparison", Path(__file__).parents[1] / "Native/compare-recognition-benchmarks.py")
comparison = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(comparison)


class BenchmarkComparisonTests(unittest.TestCase):
    def setUp(self):
        self.before = {"seconds": 100, "meetingID": "fixture", "mode": "batch-turbo", "audioSeconds": 3600,
                       "turboActivityHeld": True,
                       "recognitionPerformance": {"qwenCalls": 20, "gigaCalls": 10}, "segments": [
            {"id": "a", "start": 0, "end": 2, "audioFile": "example-remote.caf", "speaker": "Голос 1", "text": "Не переносим встречу.", "embedding": [0.2, 0.8]},
            {"id": "b", "start": 3, "end": 4, "audioFile": "example-mic.clean.caf", "speaker": "Я", "text": "Да.", "embedding": [0.3, 0.7]},
        ]}
        self.after = copy.deepcopy(self.before)
        self.after["seconds"] = 80

    def test_new_identifiers_and_unused_microphone_vectors_do_not_change_quality(self):
        self.after["segments"][0]["id"] = "new"
        self.after["segments"][1].pop("embedding")
        result = comparison.compare(self.before, self.after)
        self.assertTrue(result.get("equivalent"))
        self.assertEqual(result.get("speedup"), 1.25)
        self.assertEqual(result.get("time_saved_percent"), 20)

    def test_missing_negation_is_not_hidden_by_matching_segment_count(self):
        self.after["segments"][0]["text"] = "Переносим встречу."
        result = comparison.compare(self.before, self.after)
        self.assertIs(result.get("equivalent"), False)
        self.assertEqual(result.get("text_changes"), 1)

    def test_generated_aec_identifier_does_not_change_source_track(self):
        self.before["segments"][1]["audioFile"] = "example-mic.clean.11111111-1111-4111-8111-111111111111.caf"
        self.after["segments"][1]["audioFile"] = "example-mic.clean.22222222-2222-4222-8222-222222222222.caf"
        self.assertTrue(comparison.compare(self.before, self.after)["equivalent"])
        self.after["segments"][1]["end"] = 4.1
        self.assertFalse(comparison.compare(self.before, self.after)["equivalent"])

    def test_real_microphone_source_and_non_uuid_suffix_remain_significant(self):
        self.before["segments"][1]["audioFile"] = "example-mic.clean.11111111-1111-4111-8111-111111111111.caf"
        self.after["segments"][1]["audioFile"] = "other-mic.clean.22222222-2222-4222-8222-222222222222.caf"
        self.assertFalse(comparison.compare(self.before, self.after)["equivalent"])
        self.before["segments"][1]["audioFile"] = "example-mic.clean.first.caf"
        self.after["segments"][1]["audioFile"] = "example-mic.clean.second.caf"
        self.assertFalse(comparison.compare(self.before, self.after)["equivalent"])

    def test_missing_or_added_turn_is_reported(self):
        self.after["segments"].pop()
        result = comparison.compare(self.before, self.after)
        self.assertIs(result.get("equivalent"), False)
        self.assertEqual(result.get("removed_segments"), 1)
        result = comparison.compare(self.after, self.before)
        self.assertEqual(result.get("added_segments"), 1)

    def test_speaker_changes_are_not_counted_as_text_accuracy(self):
        self.after["segments"][0]["speaker"] = "Голос 2"
        result = comparison.compare(self.before, self.after)
        self.assertIs(result.get("equivalent"), False)
        self.assertEqual(result.get("speaker_changes"), 1)
        self.assertEqual(result.get("text_changes"), 0)

    def test_changed_remote_vector_is_reported_even_when_name_matches(self):
        self.after["segments"][0]["embedding"] = [0.21, 0.79]
        result = comparison.compare(self.before, self.after)
        self.assertIs(result.get("equivalent"), False)
        self.assertEqual(result.get("remote_embedding_changes"), 1)

    def test_duplicate_timestamps_cannot_overwrite_a_turn(self):
        duplicate = dict(self.before["segments"][0], id="c", speaker="Голос 2", text="Нет.")
        self.before["segments"].append(duplicate)
        result = comparison.compare(self.before, self.after)
        self.assertIs(result.get("equivalent"), False)
        self.assertEqual(result.get("removed_segments"), 1)

    def test_time_and_track_changes_are_detected(self):
        self.after["segments"][0]["end"] = 2.1
        self.assertIs(comparison.compare(self.before, self.after).get("equivalent"), False)
        self.after = copy.deepcopy(self.before)
        self.after["segments"][0]["audioFile"] = "other-remote.caf"
        self.assertIs(comparison.compare(self.before, self.after).get("equivalent"), False)

    def test_incomparable_or_disabled_recognition_is_rejected(self):
        for field, value in [("meetingID", "other"), ("mode", "balanced"), ("audioSeconds", 30),
                             ("segments", []), ("recognitionPerformance", {"qwenCalls": 20}),
                             ("turboActivityHeld", False)]:
            with self.subTest(field=field):
                self.after = copy.deepcopy(self.before)
                self.after[field] = value
                with self.assertRaises(ValueError):
                    comparison.compare(self.before, self.after)

    def test_small_vector_drift_is_reported_separately(self):
        self.after["segments"][0]["embedding"][0] += 1e-7
        result = comparison.compare(self.before, self.after)
        self.assertTrue(result["equivalent"])
        self.assertEqual(result["remote_embedding_exact_changes"], 1)
        self.assertEqual(result["remote_embedding_changes"], 0)

    def test_incomplete_or_duplicated_result_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "result.jsonl"
            row = json.dumps(dict(self.before, kind="result"))
            path.write_text(row + "\n")
            with self.assertRaises(ValueError):
                comparison.read_result(path)
            path.write_text(row + "\n" + row + "\nRECOGNITION_MEETING_BENCHMARK_OK\n")
            with self.assertRaises(ValueError):
                comparison.read_result(path)
            path.write_text('{"kind":"progress"}\n' + row + "\nRECOGNITION_MEETING_BENCHMARK_OK\n")
            self.assertEqual(comparison.read_result(path)["seconds"], 100)


if __name__ == "__main__":
    unittest.main()
