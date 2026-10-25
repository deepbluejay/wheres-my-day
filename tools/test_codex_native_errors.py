#!/usr/bin/env python3
# Portions derived from OpenAI Codex, tag rust-v0.163.0 (Apache-2.0):
# https://github.com/openai/codex/tree/rust-v0.163.0
# codex-rs/protocol/src/error.rs
# codex-rs/codex-api/src/sse/responses_error.rs
# codex-rs/codex-api/src/api_bridge.rs
# Modified for ActivityProbe: extract parser sections, expose the SSE entry point,
# and add type stubs and an invented-fixture harness. See THIRD_PARTY_NOTICES.md.
#
# Copyright 2025 OpenAI
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
"""Rebuild invented native error fixtures with parsers extracted from rust-v0.163.0.

Usage: test_codex_native_errors.py <pinned codex source> <temporary build directory>
Only the upstream HTTP/SSE parsers and Retryable bridge arm are compiled. Small type
stubs cover unrelated branches; the error wire envelopes are source-checked below.
No Codex executable, inference, login, personal home or remote API is used.
"""
import hashlib
import json
import os
import pathlib
import subprocess
import sys


def main():
    source = pathlib.Path(sys.argv[1]) / 'codex-rs'
    scratch = pathlib.Path(sys.argv[2]).resolve()
    if pathlib.Path('/tmp').resolve() not in scratch.parents:
        raise SystemExit('Use an expendable /tmp build directory')
    scratch.mkdir(parents=True, exist_ok=True)
    paths = ['protocol/src/error.rs', 'codex-api/src/sse/responses_error.rs', 'codex-api/src/api_bridge.rs']
    files = {p: (source / p).read_text() for p in paths}
    protocol, parser, bridge = (files[p] for p in paths)
    http = protocol[protocol.index('#[derive(Clone, Debug)]\npub struct UnexpectedResponseError'):protocol.index('\nfn truncate_text(')]
    sse = parser[parser.index('// Keep decoding'):parser.index('\n#[cfg(test)]')]
    sse = sse.replace('pub(super) fn parse_failed_response', 'pub fn parse_failed_response')
    arm = 'ApiError::Retryable { message, .. } => CodexErr::Stream(message),'
    assert arm in bridge
    stream_variant = '#[error("stream disconnected before completion: {0}")]\n    Stream(String),'
    assert stream_variant in protocol
    assert 'CodexErrorDetails::ConnectionFailed(_) | CodexErrorDetails::UnexpectedStatus(_) => {\n                CodexErrorInfo::HttpConnectionFailed' in protocol
    assert '_ => CodexErrorInfo::Other,' in protocol
    stub = r'''
use serde::Deserialize;
use serde_json::{Value, json};
use http::StatusCode;
use std::time::Duration;
type MisalignmentErrorDetails = Value;
#[derive(Debug, Clone, Copy)] struct RetryAfter;
impl RetryAfter {
  fn from_headers(_: &()) -> Option<Self> { None }
  fn from_delay(_: Duration) -> Option<Self> { Some(Self) }
}
fn json_headers_to_http_headers(_: &serde_json::Map<String, Value>) {}
fn parse_flex_unavailable(_: &Value) -> Option<ApiError> { None }
#[derive(Debug)] enum ApiError {
  Retryable { message: String, retry_after: Option<RetryAfter> }, Stream(String),
  ContextWindowExceeded, QuotaExceeded, UsageNotIncluded,
  CyberPolicy { message: String }, BioPolicy { message: String },
  MisalignmentPolicyViolation { message: String, misalignment: Option<Value> },
  InvalidPrompt { message: String }, ServerOverloaded { retry_after: Option<RetryAfter> },
  RateLimitExceeded { message: String, retry_after: Option<RetryAfter> },
}
'''
    upstream_header = '''// Portions derived from OpenAI Codex, tag rust-v0.163.0:
// https://github.com/openai/codex/tree/rust-v0.163.0
// codex-rs/protocol/src/error.rs
// codex-rs/codex-api/src/sse/responses_error.rs
// codex-rs/codex-api/src/api_bridge.rs
// Modified for ActivityProbe: extracted parsers, public SSE entry point,
// type stubs, and an invented-fixture harness.
// See ActivityProbe's THIRD_PARTY_NOTICES.md for the upstream LICENSE and NOTICE.
//
// Copyright 2025 OpenAI
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
'''
    native = upstream_header + stub + http + sse + '\n#[derive(Debug, thiserror::Error)] enum CodexErr {\n' + stream_variant + '\n}\n'
    native += 'fn bridge(error: ApiError) -> CodexErr { match error { ' + arm + ' _ => panic!("unexpected fixture branch") } }\n'
    native += r'''
fn main() {
 let inputs = vec![
  json!({"kind":"http","status":403,"body":{"error":{"code":"subscription_sharing_user_not_eligible","message":"Invented eligibility denial"}}}),
  json!({"kind":"sse","body":{"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"Invented usage denial"}}}}),
  json!({"kind":"sse","body":{"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_unavailable","message":"Invented usage unavailable"}}}})
 ];
 let fixtures: Vec<Value> = inputs.into_iter().map(|input| {
  let native = if input["kind"] == "http" {
   let error = UnexpectedResponseError {status: StatusCode::FORBIDDEN, body: input["body"].to_string(), user_message:None, url:None, cf_ray:None, request_id:None, identity_authorization_error:None, identity_error_code:None};
   json!({"message":error.to_string(),"codexErrorInfo":{"httpConnectionFailed":{"httpStatusCode":403}}})
  } else {
   let error = bridge(parse_failed_response(Some(input["body"]["response"].clone())));
   json!({"message":error.to_string(),"codexErrorInfo":"other"})
  };
  json!({"input":input,"native":native})
 }).collect();
 println!("{}", serde_json::to_string_pretty(&fixtures).unwrap());
}
'''
    (scratch / 'Cargo.toml').write_text('[package]\nname="invented-native-errors"\nversion="0.0.0"\nedition="2024"\n[dependencies]\nserde={version="1",features=["derive"]}\nserde_json="1"\nhttp="1"\nregex-lite="0.1"\nthiserror="2"\n')
    (scratch / 'src').mkdir(exist_ok=True)
    (scratch / 'src/main.rs').write_text(native)
    env = os.environ.copy()
    env['CARGO_HOME'] = str(scratch / 'cargo-home')
    run = subprocess.run(['cargo', 'run', '--quiet', '--manifest-path', str(scratch / 'Cargo.toml')], env=env,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    (scratch / 'build.log').write_text(run.stderr)
    if run.returncode:
        raise SystemExit(run.stderr)
    result = {'version':'rust-v0.163.0', 'sourceSHA256':{p:hashlib.sha256(files[p].encode()).hexdigest() for p in paths},
              'fixtures':json.loads(run.stdout)}
    expected = pathlib.Path(__file__).resolve().parent.parent / 'tests/ChatTests/Fixtures/codex-0.163.0-errors.json'
    generated = json.dumps(result, indent=2) + '\n'
    if '--write' in sys.argv:
        expected.write_text(generated)
    else:
        assert expected.read_text() == generated, 'Native conversion fixtures changed'
    print('actual pinned HTTP/SSE conversion: all passed')

if __name__ == '__main__':
    main()
