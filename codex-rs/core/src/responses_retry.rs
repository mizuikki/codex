//! Shared retry and transport fallback decisions for Responses requests.

use std::time::Duration;

use crate::client::ModelClientSession;
use crate::session::session::Session;
use crate::session::turn_context::TurnContext;
use crate::util::backoff;
use crate::util::jitter;
use codex_protocol::error::CodexErr;
use codex_protocol::error::CodexErrorDetails;
use codex_protocol::protocol::EventMsg;
use codex_protocol::protocol::WarningEvent;
use tokio_util::sync::CancellationToken;
use tracing::warn;

const SERVER_OVERLOADED_MAX_RETRIES: u64 = 3;
const SERVER_OVERLOADED_RETRY_DELAYS: [Duration; 3] = [
    Duration::from_secs(10),
    Duration::from_secs(30),
    Duration::from_secs(60),
];
const INITIAL_CONNECTION_RETRY_DELAY: Duration = Duration::from_secs(5);
const MAX_CONNECTION_RETRY_DELAY: Duration = Duration::from_secs(60);

#[derive(Debug, Clone, Copy)]
pub(crate) enum ResponsesStreamRequest {
    Sampling,
    RemoteCompactionV2,
}

pub(crate) struct ResponsesStreamRetryState {
    retries: u64,
    server_overloaded_retries: u64,
    connection_retry_delay: Duration,
}

impl Default for ResponsesStreamRetryState {
    fn default() -> Self {
        Self {
            retries: 0,
            server_overloaded_retries: 0,
            connection_retry_delay: INITIAL_CONNECTION_RETRY_DELAY,
        }
    }
}

/// Handles a retryable stream error and returns `Ok(())` when the caller should
/// retry the request loop.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_retryable_response_stream_error(
    retry_state: &mut ResponsesStreamRetryState,
    max_retries: u64,
    err: CodexErr,
    client_session: &mut ModelClientSession,
    sess: &Session,
    turn_context: &TurnContext,
    request: ResponsesStreamRequest,
    cancellation_token: &CancellationToken,
) -> Result<(), CodexErr> {
    let is_server_overloaded = matches!(err.details(), CodexErrorDetails::ServerOverloaded);
    if matches!(request, ResponsesStreamRequest::Sampling)
        && matches!(err.details(), CodexErrorDetails::ConnectionFailed(_))
        && !turn_context.session_source.is_internal()
        && !turn_context.provider.info().is_amazon_bedrock()
    {
        let retry_delay = retry_state.connection_retry_delay;
        warn!(
            turn_id = %turn_context.sub_id,
            error = %err,
            ?retry_delay,
            "stream connection failed; waiting to retry"
        );
        sess.notify_stream_error(turn_context, "Reconnecting... waiting for network", err)
            .await;
        tokio::select! {
            () = tokio::time::sleep(retry_delay) => {}
            () = cancellation_token.cancelled() => return Err(CodexErr::TurnAborted),
        }
        retry_state.connection_retry_delay = retry_delay
            .saturating_mul(2)
            .min(MAX_CONNECTION_RETRY_DELAY);
        return Ok(());
    }

    if !is_server_overloaded
        && retry_state.retries >= max_retries
        && client_session.try_switch_fallback_transport(
            &turn_context.session_telemetry,
            &turn_context.model_info,
        )
    {
        sess.send_event(
            turn_context,
            EventMsg::Warning(WarningEvent {
                message: format!("Falling back from WebSockets to HTTPS transport. {err:#}"),
            }),
        )
        .await;
        retry_state.retries = 0;
        return Ok(());
    }

    let (retry_count, retry_limit, delay) = if is_server_overloaded {
        if retry_state.server_overloaded_retries >= SERVER_OVERLOADED_MAX_RETRIES {
            return Err(err);
        }
        retry_state.server_overloaded_retries += 1;
        let retry_count = retry_state.server_overloaded_retries;
        let delay = jitter(SERVER_OVERLOADED_RETRY_DELAYS[retry_count as usize - 1]);
        (retry_count, SERVER_OVERLOADED_MAX_RETRIES, delay)
    } else if retry_state.retries < max_retries {
        retry_state.retries += 1;
        let retry_count = retry_state.retries;
        let delay = err.retry_delay().unwrap_or_else(|| backoff(retry_count));
        (retry_count, max_retries, delay)
    } else {
        return Err(err);
    };
    log_retry(request, turn_context, &err, retry_count, retry_limit, delay);

    // In release builds, hide the first websocket retry notification to reduce noisy
    // transient reconnect messages. In debug builds, keep full visibility for diagnosis.
    let report_error = is_server_overloaded
        || retry_count > 1
        || cfg!(debug_assertions)
        || !sess.services.model_client.responses_websocket_enabled();
    if report_error {
        // Surface retry information to any UI/front-end so the user understands what is
        // happening instead of staring at a seemingly frozen screen.
        sess.notify_stream_error(
            turn_context,
            format!("Reconnecting... {retry_count}/{retry_limit}"),
            err,
        )
        .await;
    }
    tokio::select! {
        () = tokio::time::sleep(delay) => Ok(()),
        () = cancellation_token.cancelled() => Err(CodexErr::TurnAborted),
    }
}

fn log_retry(
    request: ResponsesStreamRequest,
    turn_context: &TurnContext,
    err: &CodexErr,
    retries: u64,
    max_retries: u64,
    delay: Duration,
) {
    match request {
        ResponsesStreamRequest::Sampling => {
            warn!(
                turn_id = %turn_context.sub_id,
                retries,
                max_retries,
                sampling_error = %err,
                "stream disconnected - retrying sampling request ({retries}/{max_retries} in {delay:?})...",
            );
        }
        ResponsesStreamRequest::RemoteCompactionV2 => {
            warn!(
                turn_id = %turn_context.sub_id,
                retries,
                max_retries,
                compact_error = %err,
                "remote compaction v2 stream failed; retrying request after delay"
            );
        }
    }
}

#[cfg(test)]
#[path = "responses_retry_tests.rs"]
mod tests;
