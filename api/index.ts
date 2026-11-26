import { resetSql } from '../server/lib/db.js';
import { getPostgresStore } from '../server/lib/repository.js';
import { handleApiRequest } from '../server/lib/router.js';

const REQUEST_TIMEOUT_MS = 18_000;

export default {
  async fetch(request: Request): Promise<Response> {
    let timer: ReturnType<typeof setTimeout> | undefined;
    const timeoutPromise = new Promise<Response>((resolve) => {
      timer = setTimeout(() => {
        console.error(
          `[LifeCheckpoint API Timeout] ${request.method} ${request.url} exceeded ${REQUEST_TIMEOUT_MS}ms — resetting DB pool`,
        );
        resetSql();
        resolve(
          Response.json(
            { error: 'Connection timed out while contacting the database. Please try again.' },
            { status: 503, headers: { 'cache-control': 'no-store' } },
          ),
        );
      }, REQUEST_TIMEOUT_MS);
    });

    try {
      return await Promise.race([
        handleApiRequest(request, getPostgresStore()),
        timeoutPromise,
      ]);
    } finally {
      if (timer) clearTimeout(timer);
    }
  },
};
