import http from 'k6/http';
import { check, sleep } from 'k6';


// API URL from environment variable
const BASE_URL = __ENV.API_URL || 'https://your-api-url.com';

// Test configuration
export const options = {
  vus: 100,          // 100 virtual users
  duration: '30s',   // run test for 30 seconds
};

// Sample events and ticket types
const EVENTS = ['concert-1', 'concert-2'];
const TIERS = ['GA', 'VIP'];

// Helper function to pick random item
function randomItem(array) {
  return array[Math.floor(Math.random() * array.length)];
}

// Main test function
export default function () {

  // Create request body
  const payload = JSON.stringify({
    eventId: randomItem(EVENTS),
    tier: randomItem(TIERS),
    quantity: 1
  });

  // Request headers
  const params = {
    headers: {
      'Content-Type': 'application/json',
    },
  };

  // Send POST request to purchase endpoint
  const response = http.post(
    `${BASE_URL}/purchase`,
    payload,
    params
  );

  // Check if request succeeded
  check(response, {
    'purchase successful': (r) => r.status === 200,
  });

  // Small delay between requests
  sleep(1);
}