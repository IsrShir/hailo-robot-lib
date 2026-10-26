"""AUTO target selection in the H15 native-pipeline subscriber.

Pins:
1. AUTO locks onto the biggest person and reports its ID as following_id
   (so the web UI highlights it), and the lock sticks when someone bigger
   shows up.
2. The web UI's auto-select toggle (controller_config.auto_select) is
   honoured: OFF → follow nobody until the operator clicks.
3. A missing AUTO target is held for AUTO_TARGET_RELEASE_S, then AUTO
   picks again.
4. An operator click overrides AUTO; Clear returns to AUTO.
5. End to end: a ZMQ frame → ui_state.update_detections(following_id=…).
"""

from __future__ import annotations

from types import SimpleNamespace

import pytest

pytest.importorskip("zmq")

from robot_follow.follow_api.state import FollowTargetState, SharedDetectionState  # noqa: E402
from robot_follow.follow_api.types import Detection  # noqa: E402
from robot_follow.native_pipeline import subscriber as sub_mod  # noqa: E402
from robot_follow.native_pipeline.protos import analytics_metadata_pb2 as pb  # noqa: E402
from robot_follow.native_pipeline.subscriber import NativePipelineSubscriber  # noqa: E402


def _det(bh, conf=0.9, cx=0.5):
    return Detection(label="person", confidence=conf, center_x=cx, center_y=0.5,
                     bbox_height=bh, timestamp=0.0)


def _make(auto_select=True):
    ts = FollowTargetState()
    cfg = SimpleNamespace(auto_select=auto_select)
    s = NativePipelineSubscriber(SharedDetectionState(), target_state=ts,
                                 controller_config=cfg)
    return s, ts, cfg


def test_auto_locks_biggest_and_reports_it():
    s, ts, _ = _make()
    tracks = {3: _det(0.2), 7: _det(0.4)}
    det, fid = s._select_follow(tracks)
    assert fid == 7 and det is tracks[7]
    assert ts.get_target() == 7


def test_auto_lock_sticks_when_someone_bigger_appears():
    s, ts, _ = _make()
    s._select_follow({3: _det(0.2), 7: _det(0.4)})
    det, fid = s._select_follow({3: _det(0.6), 7: _det(0.4)})
    assert fid == 7


def test_auto_select_off_follows_nobody():
    s, ts, cfg = _make(auto_select=False)
    assert s._select_follow({3: _det(0.2)}) == (None, None)
    assert ts.get_target() is None
    cfg.auto_select = True  # UI toggle flips the live config object
    _, fid = s._select_follow({3: _det(0.2)})
    assert fid == 3


def test_paused_follows_nobody():
    s, ts, _ = _make()
    ts.set_paused(True)
    assert s._select_follow({3: _det(0.2)}) == (None, None)


def test_missing_auto_target_holds_then_repicks(monkeypatch):
    s, ts, _ = _make()
    now = [100.0]
    monkeypatch.setattr(sub_mod.time, "monotonic", lambda: now[0])
    monkeypatch.setattr("robot_follow.follow_api.state.time.monotonic", lambda: now[0])
    s._select_follow({7: _det(0.4)})
    now[0] += sub_mod.AUTO_TARGET_RELEASE_S / 2
    det, fid = s._select_follow({3: _det(0.2)})
    assert det is None and fid == 7  # within grace: hold, keep showing the lock
    now[0] += sub_mod.AUTO_TARGET_RELEASE_S
    det, fid = s._select_follow({3: _det(0.2)})
    assert fid == 3 and ts.get_target() == 3


def test_operator_click_overrides_auto_and_clear_returns_to_auto():
    s, ts, _ = _make()
    s._select_follow({3: _det(0.2), 7: _det(0.4)})
    ts.set_target(3)  # operator click (H15 /api/follow/3)
    _, fid = s._select_follow({3: _det(0.2), 7: _det(0.4)})
    assert fid == 3
    # Clicked target missing → legacy fallback keeps the clicked ID.
    _, fid = s._select_follow({7: _det(0.4)})
    assert fid == 3 and ts.get_target() == 3
    ts.set_target(None)  # Clear
    _, fid = s._select_follow({3: _det(0.2), 7: _det(0.4)})
    assert fid == 7


def test_handle_frame_sends_auto_id_to_ui():
    calls = []
    ui = SimpleNamespace(update_detections=lambda dets, **kw: calls.append((dets, kw)))
    ts = FollowTargetState()
    s = NativePipelineSubscriber(SharedDetectionState(), target_state=ts, ui_state=ui,
                                 controller_config=SimpleNamespace(auto_select=True))
    frame = pb.Frame(frame_width=1920, frame_height=1080)
    for (y0, y1) in ((100, 300), (100, 900)):  # second person is taller
        d = frame.detections.add(label="person", confidence=0.9)
        d.bbox.xmin, d.bbox.xmax, d.bbox.ymin, d.bbox.ymax = 100, 300, y0, y1
    s._handle_frame(frame.SerializeToString())
    (_, kw), = calls
    assert kw["following_id"] == 1  # index 1 = taller person (no ByteTracker)
    assert ts.get_target() == 1
