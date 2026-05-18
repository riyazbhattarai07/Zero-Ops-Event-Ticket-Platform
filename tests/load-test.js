// ============================================================
// load-test.js — Simulate a flash sale with thousands of users
// ============================================================
// This test uses k6 (https://k6.io) — a load testing tool.
// It pretends to be thousands of users all clicking "Buy Ticket"
// at the same time, just like a real Taylor Swift ticket drop.
//
// HOW TO RUN:
//   1. Install k6: https://k6.io/docs/getting-started/installation/
//   2. Deploy your Terraform first: make deploy
//   3. Get your API URL: terraform output api_endpoint
//   4. Get a JWT token (see README for Cognito login steps)
//   5. Run:
//        k6 run -e API_URL=https://your-url.cloudfront.net \
//                -e JWT_TOKEN=your-token \
//                tests/load-test.js
//
//   Or just use the Makefile shortcut: make test
// ============================================================

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend, Counter } from 'k6/metrics';

// -------------------------------------------------------
// Custom metrics — tracked separately from built-in k6 stats
// These show up in the summary report at the end
// -------------------------------------------------------
const errorRate      = new Rate('error_rate');              // % of requests that failed
const purchaseTrend  = new Trend('purchase_duration_ms');   // How long each request took
const soldOutCounter = new Counter('sold_out_responses');    // How many 409s (sold out)
const successCounter = new Counter('successful_reservations'); // How many tickets reserved

// -------------------------------------------------------
// Test configuration — controls how many users and when
// -------------------------------------------------------
export const options = {
  scenarios: {
    // Simulates a flash sale:
    // - Starts quiet (a few users browsing)
    // - Ramps up fast (sale goes live, everyone rushes in)
    // - Holds at peak (5000 concurrent users for 60 seconds)
    // - Dies down (people give up or succeed)
    flash_sale: {
      executor: 'ramping-vus',  // VU = Virtual User (each one runs the default function below)
      startVUs: 0,
      stages: [
        { duration: '10s', target: 100  },  // Warm up: 100 users over 10 seconds
        { duration: '30s', target: 1000 },  // Ramp up: hit 1,000 users
        { duration: '60s', target: 5000 },  // Peak: 5,000 concurrent users (flash sale open)
        { duration: '30s', target: 500  },  // Cool down: most people are done
        { duration: '10s', target: 0    },  // Wind down: test ends
      ],
    },
  },

  // Pass/fail thresholds — the test FAILS if these are not met
  thresholds: {
    http_req_duration: ['p(95)<500'],  // 95% of requests must finish in under 500ms
    error_rate:        ['rate<0.01'],  // Error rate must stay below 1%
  },
};

// -------------------------------------------------------
// Config — override with -e flags when running k6
// Example: k6 run -e API_URL=https://xyz.cloudfront.net load-test.js
// -------------------------------------------------------
const BASE_URL  = __ENV.API_URL  || 'https://your-cloudfront-domain.cloudfront.net';
const JWT_TOKEN = __ENV.JWT_TOKEN || 'your-cognito-jwt-token';

// Test data — randomly pick from these to simulate real users
const EVENTS = ['evt-taylor-swift', 'evt-coldplay', 'evt-weeknd'];
const TIERS  = ['GA', 'VIP', 'FLOOR'];

// -------------------------------------------------------
// Helper functions
// -------------------------------------------------------

// Pick a random item from an array
function randomItem(arr) {
  return arr[Math.floor(Math.random() * arr.length)];
}

// Generate a unique key to prevent duplicate purchases
// (Our API uses this for idempotency)
function randomIdempotencyKey() {
  return 'k6-' + Math.random().toString(36).substring(2, 15);
}

// -------------------------------------------------------
// DEFAULT FUNCTION — k6 runs this for every virtual user
// Each VU loops through this function for the test duration
// -------------------------------------------------------
export default function () {
  // Build a random purchase request (simulates different users buying different tickets)
  const payload = JSON.stringify({
    eventId:        randomItem(EVENTS),
    tier:           randomItem(TIERS),
    quantity:       Math.floor(Math.random() * 2) + 1,  // Buy 1 or 2 tickets
    idempotencyKey: randomIdempotencyKey(),
  });

  // Set up headers — include the JWT token for authentication
  const params = {
    headers: {
      'Content-Type':  'application/json',
      'Authorization': `Bearer ${JWT_TOKEN}`,
    },
    timeout: '10s',  // Give up after 10 seconds
  };

  // Send the purchase request and time it
  const start = Date.now();
  const res   = http.post(`${BASE_URL}/purchase`, payload, params);
  const dur   = Date.now() - start;

  // Record how long this request took
  purchaseTrend.add(dur);

  // Check the response — these checks show up in the summary
  const ok = check(res, {
    // We accept 200 (reserved) and 409 (sold out) as valid responses
    // Only 5xx errors count as failures — sold out is expected behavior!
    'status is 200 or 409': (r) => r.status === 200 || r.status === 409,
    'response has a body':  (r) => r.body && r.body.length > 0,
    'no server errors':     (r) => r.status < 500,
  });

  // Track error rate (true if the request failed)
  errorRate.add(!ok);

  // Handle each response type
  if (res.status === 200) {
    const body = JSON.parse(res.body);
    if (body.status === 'RESERVED') {
     