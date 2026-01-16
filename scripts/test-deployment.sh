#!/bin/bash
# Test the deployed bakery-game on GitHub Pages
# Run this ~1 minute after deployment to allow GitHub Pages to propagate

set -e

SITE_URL="${1:-https://labelle-toolkit.github.io/bakery-game/}"
TIMEOUT="${2:-30000}"

echo "Testing deployment at: $SITE_URL"

# Create a temporary directory for the test
TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"

# Initialize a minimal npm project and install Playwright
cat > package.json << 'EOF'
{
  "name": "deployment-test",
  "type": "module",
  "scripts": {
    "test": "node test.mjs"
  }
}
EOF

echo "Installing Playwright..."
npm install playwright --silent

# Create the test script
cat > test.mjs << EOF
import { chromium } from 'playwright';

const SITE_URL = '${SITE_URL}';
const TIMEOUT = ${TIMEOUT};

async function testDeployment() {
  console.log('Launching browser...');
  const browser = await chromium.launch();
  const context = await browser.newContext();
  const page = await context.newPage();

  const errors = [];
  const consoleLogs = [];

  // Collect console messages
  page.on('console', msg => {
    consoleLogs.push(\`[\${msg.type()}] \${msg.text()}\`);
  });

  // Collect page errors
  page.on('pageerror', error => {
    errors.push(error.message);
  });

  try {
    console.log(\`Navigating to \${SITE_URL}...\`);

    // Navigate and wait for network to be idle
    const response = await page.goto(SITE_URL, {
      waitUntil: 'networkidle',
      timeout: TIMEOUT
    });

    // Check HTTP status
    if (!response.ok()) {
      throw new Error(\`HTTP \${response.status()}: \${response.statusText()}\`);
    }
    console.log(\`Page loaded with status: \${response.status()}\`);

    // Wait for canvas element (WASM game renders to canvas)
    console.log('Waiting for canvas element...');
    await page.waitForSelector('canvas', { timeout: TIMEOUT });
    console.log('Canvas element found');

    // Check canvas has dimensions (game initialized)
    const canvasSize = await page.evaluate(() => {
      const canvas = document.querySelector('canvas');
      return { width: canvas.width, height: canvas.height };
    });

    if (canvasSize.width === 0 || canvasSize.height === 0) {
      throw new Error('Canvas has zero dimensions - game may not have initialized');
    }
    console.log(\`Canvas size: \${canvasSize.width}x\${canvasSize.height}\`);

    // Wait a moment for WASM to initialize and check for errors
    await page.waitForTimeout(2000);

    // Check for critical errors
    const criticalErrors = errors.filter(e =>
      !e.includes('ResizeObserver') // Ignore benign ResizeObserver errors
    );

    if (criticalErrors.length > 0) {
      console.error('Page errors detected:');
      criticalErrors.forEach(e => console.error(\`  - \${e}\`));
      throw new Error('Critical page errors detected');
    }

    // Log console output for debugging
    if (consoleLogs.length > 0) {
      console.log('Console output:');
      consoleLogs.slice(0, 10).forEach(log => console.log(\`  \${log}\`));
      if (consoleLogs.length > 10) {
        console.log(\`  ... and \${consoleLogs.length - 10} more\`);
      }
    }

    console.log('\\n✅ Deployment test PASSED');
    await browser.close();
    process.exit(0);

  } catch (error) {
    console.error(\`\\n❌ Deployment test FAILED: \${error.message}\`);

    // Take screenshot on failure
    const screenshotPath = '/tmp/bakery-game-test-failure.png';
    await page.screenshot({ path: screenshotPath });
    console.log(\`Screenshot saved to: \${screenshotPath}\`);

    await browser.close();
    process.exit(1);
  }
}

testDeployment();
EOF

# Install Chromium browser
echo "Installing Chromium browser..."
npx playwright install chromium --with-deps 2>/dev/null || npx playwright install chromium

# Run the test
echo ""
echo "Running deployment test..."
echo "=========================="
node test.mjs

# Cleanup
cd -
rm -rf "$TEMP_DIR"
