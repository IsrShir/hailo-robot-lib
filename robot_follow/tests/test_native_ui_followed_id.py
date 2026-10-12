"""The H15 native-pipeline subscriber reports the person it actually follows
as following_id, so the web UI highlights the AUTO (biggest-person) pick and
not only operator-clicked targets.
"""

from __future__ import annotations

from types import SimpleNamespace

import pytest

pytest.importorskip("zmq")

from robot_follow.follow_api.state import FollowTargetState, SharedDetectionState  # noqa: E402
from robot_follow.native_pipeline.protos import analytics_metadata_pb2 as pb  # noqa: E402
from robot_follow.native_pipeline.subscriber import NativePipelineSubscriber  # noqa: E402


def _run_frame(target_id=None):
    calls = []
    ui = SimpleNamespace(update_detections=lambda dets, **kw: calls.append(kw))
    ts = FollowTargetState()
    if target_id is not None:
        ts.set_target(target_id)
    shared = SharedDetectionState()
    s = NativePipelineSubscriber(shared, target_state=ts, ui_state=ui)
    frame = pb.Frame(frame_width=1920, frame_height=1080)
    for (y0, y1) in ((100, 300), (100, 900)):  # index 1 is the taller person
        d = frame.detections.add(label="person", confidence=0.9)
        d.bbox.xmin, d.bbox.xmax, d.bbox.ymin, d.bbox.ymax = 100, 300, y0, y1
    s._handle_frame(frame.SerializeToString())
    (kw,) = calls
    return kw["following_id"], ts


def test_auto_reports_biggest_person():
    following_id, ts = _run_frame()
    assert following_id == 1
    assert ts.get_target() is None  # display only: AUTO behaviour unchanged


def test_clicked_target_is_reported():
    following_id, _ = _run_frame(target_id=0)
    assert following_id == 0
