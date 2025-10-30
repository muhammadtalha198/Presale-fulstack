import express from 'express';
import axios from 'axios';
import bodyParser from 'body-parser';
import crypto from 'crypto';
import dotenv from 'dotenv';
import { ethers } from 'ethers';
dotenv.config();

const app = express();
app.use(bodyParser.json());

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
      'POST /api/verify/webhook': 'Handle Sumsub verification updates'
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
const SUMSUB_LEVEL_NAME = process.env.SUMSUB_LEVEL_NAME;

// Ethers configuration
const RPC_URL = process.env.RPC_URL;
const PRIVATE_KEY = process.env.PRIVATE_KEY;
const AUTHORIZE_CONTRACT = process.env.PRESALE_CONTRACT_ADDRESS;
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

// In-memory storage for verification status (use database in production)
const verifiedUsers = new Map(); // userId -> { verified: boolean, reviewResult: string, verifiedAt: Date, buyerAddress: string }
const userNonces = new Map(); // buyerAddress -> nonce counter (contract tracks by buyer address)

// ========== Generate Access Token ==========
app.post('/api/verify/start', (req, res, next) => {
  // Set CORS headers for this specific route
  res.header('Access-Control-Allow-Origin', '*');
  res.header('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.header('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  next();
}, async (req, res) => {
    try {
      const { userId, email, phone } = req.body;
  
      if (!userId) {
        return res.status(400).json({ error: 'Missing required field: userId' });
      }
  
      const endpoint = '/resources/accessTokens/sdk';
      const url = `${SUMSUB_BASE_URL}${endpoint}`;
      const payload = {
        userId,
        ttlInSecs: 600,
        levelName: SUMSUB_LEVEL_NAME,
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

// ========== Webhook (Handle Sumsub Updates) ==========
app.post('/api/verify/webhook', (req, res) => {
  try {
    
    const signature = req.headers['x-payload-digest'];
    const payload = JSON.stringify(req.body);

    console.log('Webhook payload:', payload);

    const expectedSig = crypto
      .createHmac('sha256', SUMSUB_SECRET_KEY)
      .update(payload)
      .digest('hex');

    if (signature !== expectedSig) {
      return res.status(403).send('Invalid signature');
    }

    const { 
      applicantId, 
      externalUserId, 
      reviewStatus, 
      reviewResult,
      levelName,
      sandboxMode 
    } = req.body;

    console.log('Verification webhook:', {
      applicantId,
      externalUserId,
      reviewStatus,
      reviewResult,
      levelName,
      sandboxMode
    });

    // ✅ Store verification status for the user
    const isVerified = reviewStatus === 'completed' && reviewResult?.reviewAnswer === 'GREEN';
    
    verifiedUsers.set(externalUserId, {
      verified: isVerified,
      reviewResult: reviewResult?.reviewAnswer || 'UNKNOWN',
      reviewStatus: reviewStatus,
      applicantId: applicantId,
      verifiedAt: new Date(),
      levelName: levelName,
      sandboxMode: sandboxMode,
      buyerAddress: null // Will be set when user requests voucher
    });

    console.log(`User ${externalUserId} verification status:`, {
      verified: isVerified,
      result: reviewResult?.reviewAnswer,
      status: reviewStatus
    });

    res.status(200).send('Webhook received');
  } catch (err) {
    console.error('Webhook error:', err);
    res.status(500).send('Webhook error');
  }
});

// ========== Generate Presale Voucher ==========
app.post('/api/presale/voucher', async (req, res) => {
  try {
    const { buyer, beneficiary, paymentToken, usdAmount, userId } = req.body;

    // Check if user is verified
    if (!userId) {
      return res.status(400).json({ error: 'User ID required' });
    }


    // Initialize signer only when needed
    try {
      const { signer: initializedSigner } = initializeSigner();
      signer = initializedSigner;
    } catch (error) {
      return res.status(500).json({ error: 'Failed to initialize signer. Check RPC_URL and PRIVATE_KEY.' });
    }

    if (!AUTHORIZE_CONTRACT) {
      return res.status(500).json({ error: 'AUTHORIZE_CONTRACT not configured' });
    }

    // Get or increment nonce for buyer address (contract tracks by buyer address)
    const nonce = userNonces.get(buyer) || 0;
    // userNonces.set(buyer, nonce + 1);
    
    // Store buyer address for this user (userId is now the wallet address)
    // userVerification.buyerAddress = buyer;
    // verifiedUsers.set(userId, userVerification);
    
    console.log(`Nonce for ${buyer}: ${nonce} -> ${nonce + 1}`);
    
    const deadline = Math.floor(Date.now() / 1000) + 3600 * 24; // 24 hours validity

    // Create voucher structure matching your contract
    const voucher = {
      buyer,
      beneficiary,
      paymentToken,
      usdLimit: ethers.parseUnits(String(usdAmount), 18).toString(), // USD (18 decimals) - convert BigInt to string
      nonce,
      deadline,
      presale: AUTHORIZE_CONTRACT
    };

    // EIP-712 domain and types (matching your contract)
    // IMPORTANT: Include verifyingContract for proper contract verification
    const domain = {
      name: "EscrowAuthorizer",
      version: "1",
      chainId: CHAIN_ID,
      verifyingContract: AUTHORIZE_CONTRACT, // Critical for contract verification!
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

    // Sign the voucher using the signer
    const signature = await signer.signTypedData(domain, types, voucher);
    
    console.log('EIP-712 signature created:', {
      signer: signer.address,
      signature: signature.substring(0, 20) + '...',
      voucher: voucher
    });

    console.log('Generated voucher:', {
      voucher,
      signature,
      userId
    });

    // Convert BigInt values to strings for JSON serialization
    const response = {
      voucher: {
        ...voucher,
        usdLimit: voucher.usdLimit.toString()
      },
      signature,
      nonce,
      deadline
    };

    res.json(response);

  } catch (err) {
    console.error('Error generating voucher:', err);
    res.status(500).json({ error: 'Failed to generate voucher' });
  }
});

// ========== Check Nonce (for debugging) ==========
app.get('/api/presale/nonce/:buyerAddress', (req, res) => {
  try {
    const { buyerAddress } = req.params;
    const nonce = userNonces.get(buyerAddress) || 0;
    
    res.json({
      buyerAddress,
      currentNonce: nonce,
      nextNonce: nonce + 1
    });
  } catch (err) {
    console.error('Error checking nonce:', err);
    res.status(500).json({ error: 'Failed to check nonce' });
  }
});

app.listen(3000, () => console.log('✅ Server running on http://localhost:3000'));
