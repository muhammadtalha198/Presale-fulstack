# Environment Variables Required

Create a `.env` file in the `backened` directory with these variables:

## Required Variables

```env
# ========== Sumsub KYC Configuration ==========
SUMSUB_BASE_URL=https://api.sumsub.com
SUMSUB_APP_TOKEN=your_sumsub_app_token_here
SUMSUB_SECRET_KEY=your_sumsub_secret_key_here
SUMSUB_LEVEL_NAME=basic-kyc

# ========== Blockchain Configuration ==========
RPC_URL=https://sepolia.infura.io/v3/
PRIVATE_KEY=your_wallet_private_key_here
AUTHORIZE_CONTRACT=0x1234567890123456789012345678901234567890
CHAIN_ID=11155111
```

## Optional Variables (Alternative Names)

```env
# These are also supported for backward compatibility
BACKEND_PRIVATE_KEY=your_wallet_private_key_here
PRESALE_CONTRACT_ADDRESS=0x1234567890123456789012345678901234567890
```

## How to Get These Values

### 1. Sumsub Configuration
- Go to [Sumsub Dashboard](https://sumsub.com)
- Create an application
- Get your `APP_TOKEN` and `SECRET_KEY`
- Set `SUMSUB_LEVEL_NAME` to your verification level (e.g., "basic-kyc")

### 2. Blockchain Configuration
- **RPC_URL**: Using Infura Sepolia testnet endpoint with your key
- **PRIVATE_KEY**: Your wallet's private key (the one that will sign vouchers)
- **AUTHORIZE_CONTRACT**: Address of your deployed Authorizer contract
- **CHAIN_ID**: 
  - Mainnet: `1`
  - Sepolia: `11155111`
  - Local: `31337`

## Testing Setup

For testing, you can use:
- **Sepolia testnet**: `CHAIN_ID=11155111`
- **Local development**: `RPC_URL=http://localhost:8545`

## Security Notes

- Never commit your `.env` file to version control
- Keep your private key secure
- Use testnet for development
- Use a dedicated wallet for signing (not your main wallet)
