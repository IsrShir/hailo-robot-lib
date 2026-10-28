"""POST /api/follow/* on the web UI port reaches the FollowServer.

The UI posts clicks to its own origin, so they work through an ssh tunnel
on any local port; WebServer forwards them to the FollowServer.
"""

import json
import socket
import time
from http.client import HTTPConnection

import pytest

from robot_follow.follow_api.state import FollowTargetState, SharedDetectionState
from robot_follow.servers import FollowServer
from robot_follow.servers.web_server import SharedUIState, WebServer


def _free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _post(port, path, body=None):
    conn = HTTPConnection("127.0.0.1", port, timeout=5)
    headers = {"Content-Type": "application/json"} if body is not None else {}
    conn.request("POST", path, body=json.dumps(body) if body is not None else None,
                 headers=headers)
    resp = conn.getresponse()
    data = resp.read()
    conn.close()
    return resp.status, data


@pytest.fixture
def servers():
    target_state = FollowTargetState()
    shared_state = SharedDetectionState()
    follow = FollowServer(target_state, shared_state, host="127.0.0.1", port=_free_port())
    web = WebServer(SharedUIState(), target_state=target_state, shared_state=shared_state,
                    host="127.0.0.1", port=_free_port(), follow_server_port=follow.port)
    follow.start()
    web.start()
    time.sleep(0.1)
    yield web, target_state, shared_state
    web.stop()
    follow.stop()
    time.sleep(0.1)


def test_follow_click_is_forwarded(servers):
    web, target_state, shared_state = servers
    shared_state.update(None, available_ids={5})
    status, data = _post(web.port, "/api/follow/5",
                         {"bbox": {"x": 0.1, "y": 0.1, "w": 0.1, "h": 0.2}})
    assert status == 200
    assert json.loads(data)["following_id"] == 5
    assert target_state.get_target() == 5


def test_follow_clear_is_forwarded(servers):
    web, target_state, shared_state = servers
    target_state.set_target(5)
    status, _ = _post(web.port, "/api/follow/clear")
    assert status == 200
    assert target_state.get_target() is None


def test_follow_error_status_is_passed_through(servers):
    web, _, shared_state = servers
    shared_state.update(None, available_ids={1})
    status, data = _post(web.port, "/api/follow/99")
    assert status == 404
    assert json.loads(data)["status"] == "error"


def test_no_forward_loop_when_follow_port_is_own_port():
    port = _free_port()
    web = WebServer(SharedUIState(), host="127.0.0.1", port=port, follow_server_port=port)
    web.start()
    time.sleep(0.1)
    try:
        status, _ = _post(port, "/api/follow/1")
        assert status == 404
    finally:
        web.stop()
