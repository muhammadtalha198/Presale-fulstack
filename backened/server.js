import express from 'express';
import axios from 'axios';
import bodyParser from 'body-parser';
import crypto from 'crypto';
import dotenv from 'dotenv';
import { ethers } from 'ethers';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

dotenv.config();

// Get directory name for ES modules
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);


const app = express();
// Parse JSON for most routes
app.use(bodyParser.json());
// Keep raw body for webhook signature verification
app.use('/api/verify/webhook', express.raw({ type: 'application/json' }));


// Enable CORS for all routes
app.use((req, res, next) => {
  res.header('Access-Control-Allow-Origin', '*');
  res.header('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS, PATCH');
  res.header('Access-Control-Allow-Headers', 'Origin, X-Requested-With, Content-Type, Accept, Authorization, X-App-Token, X-App-Access-Sig');
  res.header('Access-Control-Allow-Credentials', 'true');
  res.header('Access-Control-Max-Age', '86400');
  if (req.method === 'OPTIONS') {
    res.status(200).end();
  } else {
    next();
  }
});


// ========== Health Check Route ==========
app.get('/', (req, res) => {
  res.json({
    message: 'Backend server is running!',
    status: 'OK',
    endpoints: {
      'POST /api/verify/start': 'Generate Sumsub access token',
      'POST /api/verify/webhook': 'Handle Sumsub verification webhooks (applicantReviewed)',
      'GET /api/verify/status/:userId': 'Check user verification status',
      'POST /api/presale/voucher': 'Generate presale voucher (requires verification)'
    }
  });
});


app.get('/api/health', (req, res) => {
  res.json({ status: 'OK', timestamp: new Date().toISOString() });
});


app.get('/api/config', (req, res) => {
  res.json({
    hasBaseUrl: !!SUMSUB_BASE_URL,
    hasAppToken: !!SUMSUB_APP_TOKEN,
    hasSecretKey: !!SUMSUB_SECRET_KEY,
    baseUrl: SUMSUB_BASE_URL,
    appTokenLength: SUMSUB_APP_TOKEN?.length || 0,
    secretKeyLength: SUMSUB_SECRET_KEY?.length || 0,
    // Don't expose actual tokens for security
    appTokenPreview: SUMSUB_APP_TOKEN ? `${SUMSUB_APP_TOKEN.substring(0, 8)}...` : 'Not set',
    secretKeyPreview: SUMSUB_SECRET_KEY ? `${SUMSUB_SECRET_KEY.substring(0, 8)}...` : 'Not set'
  });
});


const SUMSUB_BASE_URL = process.env.SUMSUB_BASE_URL;
const SUMSUB_APP_TOKEN = process.env.SUMSUB_APP_TOKEN;
const SUMSUB_SECRET_KEY = process.env.SUMSUB_SECRET_KEY;
const SUMSUB_LEVEL_NAME_US = process.env.SUMSUB_LEVEL_NAME_US;
const SUMSUB_LEVEL_NAME_OTHER = process.env.SUMSUB_LEVEL_NAME_OTHER;


// Ethers configuration
const RPC_URL = process.env.RPC_URL;
const PRIVATE_KEY = process.env.PRIVATE_KEY;
const AUTHORIZE_CONTRACT = process.env.AUTHORIZE_CONTRACT_ADDRESS;
const PRESALE_CONTRACT = process.env.PRESALE_CONTRACT_ADDRESS;

const CHAIN_ID = parseInt(process.env.CHAIN_ID);


// Ethers configuration (will be initialized when needed)
let provider, signer;


const initializeSigner = () => {
  if (!provider || !signer) {
    if (RPC_URL && PRIVATE_KEY) {
      provider = new ethers.JsonRpcProvider(RPC_URL);
      signer = new ethers.Wallet(PRIVATE_KEY, provider);
      console.log(`✅ Ethers signer initialized: ${signer.address}`);
    } else {
      throw new Error('RPC_URL or PRIVATE_KEY not set - cannot initialize signer');
    }
  }
  return { provider, signer };
};


// Storage file path
const STORAGE_FILE = path.join(__dirname, 'storage.json');

// In-memory storage for verification status (persisted to file)
const verifiedUsers = new Map(); // userId -> { verified: boolean, reviewResult: string, verifiedAt: Date, buyerAddress: string }
const userNonces = new Map(); // buyerAddress -> nonce counter (contract tracks by buyer address)

// ========== File Storage Functions ==========

/**
 * Load data from storage file
 */
function loadStorage() {
  try {
    if (fs.existsSync(STORAGE_FILE)) {
      const raw = fs.readFileSync(STORAGE_FILE, 'utf8').trim();
      if (!raw) {
        console.warn('📝 Storage file is empty; initializing new storage.json');
        saveStorage();
        return;
      }

      let data;
      try {
        data = JSON.parse(raw);
      } catch (parseErr) {
        console.error('❌ Invalid JSON in storage file; reinitializing storage.json');
        saveStorage();
        return;
      }

      // Load verifiedUsers
      if (data.verifiedUsers) {
        Object.entries(data.verifiedUsers).forEach(([key, value]) => {
          // Convert verifiedAt string back to Date object
          if (value.verifiedAt) {
            value.verifiedAt = new Date(value.verifiedAt);
          }
          verifiedUsers.set(key, value);
        });
      }

      // Load userNonces
      if (data.userNonces) {
        Object.entries(data.userNonces).forEach(([key, value]) => {
          userNonces.set(key, value);
        });
      }

      console.log(`✅ Loaded ${verifiedUsers.size} verified users and ${userNonces.size} nonces from storage`);
    } else {
      console.log('📝 No existing storage file found; creating storage.json');
      saveStorage();
    }
  } catch (error) {
    console.error('❌ Error loading storage:', error);
    console.log('⚠️ Starting with empty storage and creating storage.json');
    try { saveStorage(); } catch { }
  }
}

/**
 * Save data to storage file
 */
function saveStorage() {
  try {
    // Convert Maps to plain objects for JSON serialization
    const verifiedUsersObj = {};
    verifiedUsers.forEach((value, key) => {
      // Convert Date to ISO string for JSON serialization
      verifiedUsersObj[key] = {
        ...value,
        verifiedAt: value.verifiedAt instanceof Date ? value.verifiedAt.toISOString() : value.verifiedAt
      };
    });

    const userNoncesObj = {};
    userNonces.forEach((value, key) => {
      userNoncesObj[key] = value;
    });

    const data = {
      verifiedUsers: verifiedUsersObj,
      userNonces: userNoncesObj,
      lastUpdated: new Date().toISOString()
    };

    fs.writeFileSync(STORAGE_FILE, JSON.stringify(data, null, 2), 'utf8');
    console.log(`💾 Storage saved: ${verifiedUsers.size} verified users, ${userNonces.size} nonces`);
  } catch (error) {
    console.error('❌ Error saving storage:', error);
  }
}

// Load storage on startup
// loadStorage();


// ========== Generate Access Token ==========
app.post('/api/verify/start', (req, res, next) => {
  // Set CORS headers for this specific route
  res.header('Access-Control-Allow-Origin', '*');
  res.header('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.header('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  next();
}, async (req, res) => {
  try {
    const { userId, email, phone, country } = req.body;
    if (!userId) {
      return res.status(400).json({ error: 'Missing required field: userId' });
    }
    if (!country) {
      return res.status(400).json({ error: 'Missing required field: country' });
    }

    console.log('country:', country);

    const levelName = country === 'US' ? SUMSUB_LEVEL_NAME_US : SUMSUB_LEVEL_NAME_OTHER;

    console.log('levelName:', levelName);

    const endpoint = '/resources/accessTokens/sdk';
    const url = `${SUMSUB_BASE_URL}${endpoint}`;
    const payload = {
      userId,
      ttlInSecs: 600,
      levelName: levelName,
      applicantIdentifiers: {
        ...(email && { email }),
        ...(phone && { phone }),
      },
    };
    // Required Sumsub signature components
    const ts = Math.floor(Date.now() / 1000); // UNIX timestamp in seconds
    const method = 'POST';
    // Create signature: ts + method + endpoint + body
    const hmac = crypto.createHmac('sha256', SUMSUB_SECRET_KEY);
    hmac.update(ts + method + endpoint + JSON.stringify(payload));
    const signature = hmac.digest('hex');
    // Make authenticated request
    const response = await axios.post(url, payload, {
      headers: {
        'Content-Type': 'application/json',
        'X-App-Token': SUMSUB_APP_TOKEN,
        'X-App-Access-Ts': ts,
        'X-App-Access-Sig': signature,
      },
    });
    res.json({
      token: response.data.token,
      userId: response.data.userId,
    });
  } catch (err) {
    console.error('❌ Error generating access token:', {
      message: err.message,
      status: err.response?.status,
      data: err.response?.data,
    });
    res.status(500).json({
      error: 'Failed to generate access token',
      details: err.response?.data || err.message,
      status: err.response?.status,
    });
  }
});

/**
* Run AML recheck for an applicantId
* Requires SUMSUB_BASE_URL, SUMSUB_APP_TOKEN, SUMSUB_SECRET_KEY
*/
async function runAmlCheck(applicantId) {
  const endpoint = `/resources/applicants/${applicantId}/recheck/aml`;
  const url = `${SUMSUB_BASE_URL}${endpoint}`;
  const ts = Math.floor(Date.now() / 1000);
  const method = 'POST';
  const payload = {}; // endpoint expects empty body
  const hmac = crypto.createHmac('sha256', SUMSUB_SECRET_KEY);
  hmac.update(ts + method + `/resources/applicants/${applicantId}/recheck/aml` + JSON.stringify(payload));
  const signature = hmac.digest('hex');

  const resp = await axios.post(url, payload, {
    headers: {
      'Content-Type': 'application/json',
      'X-App-Token': SUMSUB_APP_TOKEN,
      'X-App-Access-Ts': ts,
      'X-App-Access-Sig': signature,
    },
  });
  return resp.data; // { ok: 1 } on success
}

/**
 * Get most recent AML case for an applicant
 */
async function getAmlCase(applicantId) {
  const endpoint = `/resources/api/applicants/${applicantId}/amlCase`;
  const url = `${SUMSUB_BASE_URL}${endpoint}`;
  const ts = Math.floor(Date.now() / 1000);
  const method = 'GET';
  const hmac = crypto.createHmac('sha256', SUMSUB_SECRET_KEY);
  // For GET, body is empty string
  hmac.update(ts + method + `/resources/api/applicants/${applicantId}/amlCase` + '');
  const signature = hmac.digest('hex');

  const resp = await axios.get(url, {
    headers: {
      'X-App-Token': SUMSUB_APP_TOKEN,
      'X-App-Access-Ts': ts,
      'X-App-Access-Sig': signature,
    },
  });
  return resp.data; // full AML case JSON
}



// ========== Webhook (Handle Sumsub Updates) ==========
app.post('/api/verify/webhook', async (req, res) => {
  try {
    // Parse raw body (already parsed by express.raw middleware)
    const rawBody = req.body instanceof Buffer ? req.body.toString('utf8') : req.body;
    const payload = typeof rawBody === 'string' ? JSON.parse(rawBody) : rawBody;
    const webhookType = payload.type;

    // console.log('📥 Webhook received:', {
    //   type: webhookType,
    //   applicantId: payload.applicantId,
    //   externalUserId: payload.externalUserId,
    //   reviewStatus: payload.reviewStatus,
    //   reviewAnswer: payload.reviewResult?.reviewAnswer
    // });


    // Handle applicantReviewed webhook
    if (webhookType === 'applicantReviewed') {
      const { externalUserId, reviewResult, applicantId } = payload;
      const reviewAnswer = reviewResult?.reviewAnswer;

      if (!externalUserId) {
        console.error('❌ Missing externalUserId in webhook payload');
        return res.status(400).json({ error: 'Missing externalUserId' });
      }


      // Update verification status in memory and save to file
      const isVerified = reviewAnswer === 'GREEN';
      verifiedUsers.set(externalUserId, {
        verified: isVerified,
        reviewResult: reviewAnswer,
        reviewStatus: payload.reviewStatus,
        verifiedAt: new Date(),
        applicantId: applicantId,
        buyerAddress: externalUserId // externalUserId is the wallet address
      });

      // Save to file for persistence
      saveStorage();




      // If applicant is approved (GREEN) -> run AML check only if AML not already saved.
      if (isVerified && applicantId) {
        try {
          const existing = verifiedUsers.get(externalUserId) || {};

          // ✅ IMPORTANT: if AML already screened OR currently running, skip recheck
          if (existing.aml?.screened || existing.aml?.inProgress) {
            console.log(`ℹ️ AML already processed or running for ${externalUserId}, skipping recheck.`);
          } else {
            // ✅ Mark AML as in progress BEFORE triggering recheck
            existing.aml = { inProgress: true, updatedAt: new Date() };
            verifiedUsers.set(externalUserId, existing);
            saveStorage();

            console.log(`🔎 Running AML check for applicantId=${applicantId}`);
            const amlresponse = await runAmlCheck(applicantId); // triggers screening
            console.log('✅ AML check response:', amlresponse);

            await new Promise(r => setTimeout(r, 2000)); // small wait
          }

          // ✅ Always fetch AML case (once available)
          const amlCase = await getAmlCase(applicantId);

          existing.aml = {
            screened: true,
            raw: amlCase,
            reviewAnswer: amlCase?.review?.reviewAnswer || amlCase?.reviewAnswer || null,
            riskLabels: amlCase?.riskLabels || [],
            hits: amlCase?.hits || [],
            updatedAt: new Date()
          };

          verifiedUsers.set(externalUserId, existing);
          saveStorage();

          console.log(`✅ AML stored for ${externalUserId}:`, existing.aml.reviewAnswer);

        } catch (err) {
          console.error('❌ AML Error:', err?.response?.data || err.message);
        }
      }


      console.log(`✅ User ${externalUserId} verification status updated:`, {
        verified: isVerified,
        reviewAnswer: reviewAnswer,
        reviewStatus: payload.reviewStatus
      });


      return res.status(200).json({
        success: true,
        message: 'Webhook processed',
        userId: externalUserId,
        verified: isVerified
      });
    }

    return res.status(200).json({ success: true, message: 'Webhook received' });


  } catch (err) {
    console.error('❌ Error processing webhook:', err);
    return res.status(500).json({ error: 'Failed to process webhook', details: err.message });
  }
});


// ========== Check Verification Status ==========
app.get('/api/verify/status/:userId', (req, res) => {
  try {
    const { userId } = req.params;

    if (!userId) {
      return res.status(400).json({ error: 'User ID required' });
    }


    const verificationData = verifiedUsers.get(userId);

    if (!verificationData) {
      return res.json({
        verified: false,
        status: 'pending',
        message: 'User verification not found'
      });
    }


    return res.json({
      verified: verificationData.verified,
      status: verificationData.reviewStatus || (verificationData.verified ? 'verified' : 'rejected'),
      reviewAnswer: verificationData.reviewResult,
      verifiedAt: verificationData.verifiedAt,
      applicantId: verificationData.applicantId,
      aml: verificationData.aml || { screened: false, reviewAnswer: null }
    });


  } catch (err) {
    console.error('❌ Error checking verification status:', err);
    return res.status(500).json({ error: 'Failed to check verification status' });
  }
});

// ========== Generate Presale Voucher ==========
app.post('/api/presale/voucher', async (req, res) => {
  try {
    const { buyer, beneficiary, paymentToken, usdAmount, userId, usernonce, decimals } = req.body;

    console.log('usdAmount:', usdAmount);

    if (!userId) return res.status(400).json({ error: 'User ID is required.' });
    
    if (!buyer || !beneficiary)
      return res.status(400).json({ error: 'Buyer and beneficiary are required.' });
    
    if (!usdAmount)
      return res.status(400).json({ error: 'Valid usdAmount is required.' });
    
    if (usernonce === undefined)
      return res.status(400).json({ error: 'Nonce (usernonce) is required.' });
    
    if (!decimals || isNaN(decimals))
      return res.status(400).json({ error: 'Token decimals are required.' });

    if (!AUTHORIZE_CONTRACT)
      return res.status(500).json({ error: 'AUTHORIZE_CONTRACT not configured.' });
    if (!PRESALE_CONTRACT)
      return res.status(500).json({ error: 'PRESALE_CONTRACT not configured.' });

    // Normalize decimals sent from frontend (0-18, default 8 if invalid)
    let usdDecimals = Number(decimals);
    console.log('usdDecimals:', usdDecimals);


       // ====== Initialize Signer ======
       if (!signer) {
        try {
          const { signer: initializedSigner } = initializeSigner();
          signer = initializedSigner;
        } catch (error) {
          console.error('Signer initialization failed:', error);
          return res.status(500).json({ error: 'Failed to initialize signer.' });
        }
      }

    const deadline = Math.floor(Date.now() / 1000) + 3600 * 24; // 24 hours validity

    console.log(`\n🎫 Generating Presale Voucher:
      Buyer: ${buyer}
      Beneficiary: ${beneficiary}
      PaymentToken: ${paymentToken}
      USD Amount: ${usdAmount}
      Decimals: ${decimals}
      Nonce: ${usernonce}
      Authorizer: ${AUTHORIZE_CONTRACT}
      Presale: ${PRESALE_CONTRACT}
      Chain ID: ${CHAIN_ID}
    `);

    
    console.log('usdAmount:', ethers.parseUnits(String(usdAmount), usdDecimals).toString(),);

    const voucher = {
      buyer,
      beneficiary,
      paymentToken,
      usdLimit: ethers.parseUnits(String(usdAmount), usdDecimals).toString(),
      nonce: usernonce,
      deadline,
      presale: PRESALE_CONTRACT
    };

    const domain = {
      name: "EscrowAuthorizer",
      version: "1",
      chainId: CHAIN_ID,
      verifyingContract: AUTHORIZE_CONTRACT,
    };

    const types = {
      Voucher: [
        { name: "buyer", type: "address" },
        { name: "beneficiary", type: "address" },
        { name: "paymentToken", type: "address" },
        { name: "usdLimit", type: "uint256" },
        { name: "nonce", type: "uint256" },
        { name: "deadline", type: "uint256" },
        { name: "presale", type: "address" },
      ],
    };

    const signature = await signer.signTypedData(domain, types, voucher);

    console.log('✅ Generated voucher:', { voucher, signature, userId });

    res.json({
      voucher: {
        ...voucher,
        usdLimit: voucher.usdLimit.toString()
      },
      signature,
      nonce: usernonce,
      deadline
    });

  } catch (err) {
    console.error('❌ Error generating voucher:', err);
    res.status(500).json({ error: 'Failed to generate voucher' });
  }
});


app.listen(3000, () => console.log('✅ Server running on http://localhost:3000'));