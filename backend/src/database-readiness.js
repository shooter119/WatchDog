/**
 * Keep the HTTP listener available while an asynchronous database bootstrap is
 * in progress, but let the first business request wait for that bootstrap.
 * This avoids turning a normal cold start into a user-visible 503.
 */
function createDatabaseReadiness(readyPromise, {
  waitMs = 8000,
  onReady = () => {},
  onError = () => {},
} = {}) {
  let ready = !readyPromise;
  let error = null;

  const completion = readyPromise
    ? Promise.resolve(readyPromise).then(
      () => {
        ready = true;
        onReady();
      },
      (reason) => {
        error = reason;
        onError(reason);
      },
    )
    : Promise.resolve();

  async function wait() {
    if (ready || error) return ready;
    let timer;
    try {
      await Promise.race([
        completion,
        new Promise((resolve) => {
          timer = setTimeout(resolve, Math.max(0, Number(waitMs) || 0));
        }),
      ]);
    } finally {
      if (timer) clearTimeout(timer);
    }
    return ready;
  }

  return {
    get ready() { return ready; },
    get error() { return error; },
    wait,
  };
}

module.exports = { createDatabaseReadiness };
