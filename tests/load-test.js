import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend, Counter } from 'k6/metrics';

// ─────────────────────────────────────────────
// Custom metrics
// ─────────────────────────────────────────────
const errorRate       = new Rate('error_rate');
const purchaseTrend   = new Trend('purchase_duration_ms');
const soldOutCounter  = new Counter('sold_out_responses');
const successCounter  = new Counter('successful_reservations');

// ─────────────────────────────────────────────
// Test configuration
// ─────────────────────────────────────────────
export const options = {
  scenarios: {
    // Scenario 1: Ramp up to simulate flash sale opening
    flash_sale: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '10s', target: 100  },  // Ramp to 100 users
        { duration: '30s', target: 1000 },  // Ramp to 1,000 users (flash sale)
        { duration: '60s', target: 5000 },  // Peak: 5,000 concurrent
        { duration: '30s', target: 500  },  // Cool down
        { duration: '10s', target: 0    },  // Wind down
      ],
    },
  },
  thresholds: {
    // 95% of requests must complete within 500ms
    http_req_duration: ['p(95)<500'],
    // Error rate must stay below 1%
    error_rate:        ['rate<0.01'],
    // All requests must complete within 2 seconds
    http_req_duration: ['max<2000'],
  },
};

// ─────────────────────────────────────────────
// Config — override with k6 -e flags:
//   k6 run -e API_URL=https://xyz.cloudfront.net load-test.js
// ─────────────────────────────────────────────
const BASE_URL  = __ENV.API_URL  || 'https://your-cloudfront-domain.cloudfront.net';
const JWT_TOKEN = __ENV.JWT_TOKEN || 'your-cognito-jwt-token';

const EVENTS = ['evt-taylor-swift', 'evt-coldplay', 'evt-weeknd'];
const TIERS  = ['GA', 'VIP', 'FLOOR'];

// ─────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────
function randomItem(arr) {
  return arr[Math.floor(Math.random() * arr.length)];
}

function randomIdempotencyKey() {
  return 'k6-' + Math.random().toString(36).substring(2, 15);
}

// ─────────────────────────────────────────────
// Default function — runs for each VU
// ─────────────────────────────────────────────
export default function () {
  const payload = JSON.stringify({
    eventId:        randomItem(EVENTS),
    tier:           randomItem(TIERS),
    quantity:       Math.floor(Math.random() * 2) + 1,  // 1 or 2 tickets
    idempotencyKey: randomIdempotencyKey(),
  });

  const params = {
    headers: {
      'Content-Type':  'application/json',
      'Authorization': `Bearer ${JWT_TOKEN}`,
    },
    timeout: '10s',
  };

  const start = Date.now();
  const res   = http.post(`${BASE_URL}/purchase`, payload, params);
  const dur   = Date.now() - start;

  purchaseTrend.add(dur);

  // ── Evaluate response ──
  const ok = check(res, {
    'status is 200 or 409': (r) => r.status === 200 || r.status === 409,
    'response has body':    (r) => r.body && r.body.length > 0,
    'no 5xx errors':        (r) => r.status < 500,
  });

  errorRate.add(!ok);

  if (res.status === 200) {
    const body = JSON.parse(res.body);
    if (body.status === 'RESERVED') {
      successCounter.add(1);
      console.log(`✅ Reserved: ${body.reservationId} (${dur}ms)`);
    }
  } else if (res.status === 409) {
    soldOutCounter.add(1);
  } else if (res.status >= 500) {
    console.error(`❌ Server error ${res.status}: ${res.body}`);
  }

  // Simulate human think time between clicks (0.1 - 0.5s)
  sleep(Math.random() * 0.4 + 0.1);
}

// ─────────────────────────────────────────────
// Summary report printed after test
// ─────────────────────────────────────────────
export function handleSummary(data) {
  const metrics = data.metrics;
  const p95     = metrics.http_req_duration?.values?.['p(95)']?.toFixed(2) ?? 'N/A';
  const p99     = metrics.http_req_duration?.values?.['p(99)']?.toFixed(2) ?? 'N/A';
  const errRate = ((metrics.error_rate?.values?.rate ?? 0) * 100).toFixed(2);
  const success = metrics.successful_reservations?.values?.count ?? 0;
  const soldOut = metrics.sold_out_responses?.values?.count ?? 0;
  const total   = metrics.http_reqs?.values?.count ?? 0;

  const report = `
╔══════════════════════════════════════════════════╗
║      Zero-Ops Ticket Platform — Load Test        ║
╠══════════════════════════════════════════════════╣
║  Total Requests  : ${String(total).padEnd(28)}║
║  Successful Res. : ${String(success).padEnd(28)}║
║  Sold Out (409)  : ${String(soldOut).padEnd(28)}║
║  Error Rate      : ${(errRate + '%').padEnd(28)}║
║  p95 Latency     : ${(p95 + 'ms').padEnd(28)}║
║  p99 Latency     : ${(p99 + 'ms').padEnd(28)}║
╚══════════════════════════════════════════════════╝
`;

  console.log(report);

  return {
    'tests/load-test-result.txt': report,
    stdout: report,
  };
}
