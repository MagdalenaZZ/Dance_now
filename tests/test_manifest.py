import unittest

from dance_now.manifest import (
    ManifestItem,
    dumps_manifest,
    frame_num_for_seconds,
    loads_manifest,
    nearest_video_size,
    output_key,
    parse_s3_uri,
)


class ManifestTests(unittest.TestCase):
    def test_manifest_round_trip(self):
        items = [
            ManifestItem(
                input_uri="s3://my-bucket/in/cat.jpg",
                output_uri="s3://my-bucket/out/cat.mp4",
                prompt="The cat turns toward the camera",
                seed=42,
            )
        ]
        self.assertEqual(loads_manifest(dumps_manifest(items)), items)

    def test_manifest_round_trip_with_explicit_size_and_frames(self):
        items = [
            ManifestItem(
                input_uri="s3://my-bucket/in/portrait.jpg",
                output_uri="s3://my-bucket/out/portrait.mp4",
                prompt="She looks up",
                seed=7,
                video_size="704*1280",
                frame_num=97,
            )
        ]
        self.assertEqual(loads_manifest(dumps_manifest(items)), items)

    def test_loads_manifest_rejects_unsupported_video_size(self):
        payload = (
            '{"version": 1, "items": [{"input_uri": "s3://b/in.jpg", '
            '"output_uri": "s3://b/out.mp4", "prompt": "p", "seed": 0, '
            '"video_size": "999*999", "frame_num": 121}]}'
        )
        with self.assertRaisesRegex(ValueError, "Unsupported video_size"):
            loads_manifest(payload)

    def test_loads_manifest_rejects_bad_frame_num(self):
        payload = (
            '{"version": 1, "items": [{"input_uri": "s3://b/in.jpg", '
            '"output_uri": "s3://b/out.mp4", "prompt": "p", "seed": 0, '
            '"video_size": "1280*704", "frame_num": 100}]}'
        )
        with self.assertRaisesRegex(ValueError, "4n\\+1"):
            loads_manifest(payload)

    def test_nearest_video_size_prefers_matching_orientation(self):
        self.assertEqual(nearest_video_size(700, 1250), "720*1280")
        self.assertEqual(nearest_video_size(1250, 700), "1280*720")

    def test_frame_num_for_seconds_rounds_to_4n_plus_1(self):
        self.assertEqual(frame_num_for_seconds(5.04), 121)
        for seconds in (1, 2.5, 4, 8, 10):
            frame_num = frame_num_for_seconds(seconds)
            self.assertEqual((frame_num - 1) % 4, 0)

    def test_frame_num_for_seconds_rejects_too_short(self):
        with self.assertRaises(ValueError):
            frame_num_for_seconds(0.5)

    def test_parse_s3_uri_rejects_non_object_uris(self):
        for uri in ["https://bucket/key", "s3://bucket", "s3:///key", "garbage"]:
            with self.subTest(uri=uri), self.assertRaises(ValueError):
                parse_s3_uri(uri)

    def test_output_key_is_stable_and_sanitized(self):
        self.assertEqual(
            output_key("outputs/job", "inputs/My cat!.jpeg", 3),
            "outputs/job/0003-My-cat.mp4",
        )

    def test_empty_manifest_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "no images"):
            loads_manifest('{"version": 1, "items": []}')
