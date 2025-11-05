# Postman API Testing Guide

## Server Base URL
```
http://localhost:3000
```

---

## 1. Check Verification Status

**GET** `/api/verify/status/:userId`

### Postman Setup:
- **Method**: `GET`
- **URL**: `http://localhost:3000/api/verify/status/0xb19094a082Baf95AAEb8A91F1D83D5C3028d4222`
- **Headers**: None required

### Example URL:
```
http://localhost:3000/api/verify/status/0xb19094a082Baf95AAEb8A91F1D83D5C3028d4222
```

### Response (Not Verified):
```json
{
  "verified": false,
  "status": "pending",
  "message": "User verification not found"
}
```

### Response (Verified):
```json
{
  "verified": true,
  "status": "completed",
  "reviewAnswer": "GREEN",
  "verifiedAt": "2024-01-15T10:30:00.000Z",
  "applicantId": "applicant123"
}
```

---

## 2. Start Verification (Generate Access Token)

**POST** `/api/verify/start`

### Postman Setup:
- **Method**: `POST`
- **URL**: `http://localhost:3000/api/verify/start`
- **Headers**: 
  - `Content-Type: application/json`
- **Body** (raw JSON):
```json
{
  "userId": "0xb19094a082Baf95AAEb8A91F1D83D5C3028d4222",
  "email": "user@example.com",
  "phone": "+1234567890"
}
```

### Response:
```json
{
  "token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
  "userId": "0xb19094a082Baf95AAEb8A91F1D83D5C3028d4222"
}
```

---

## 3. Generate Presale Voucher

**POST** `/api/presale/voucher`

### Postman Setup:
- **Method**: `POST`
- **URL**: `http://localhost:3000/api/presale/voucher`
- **Headers**: 
  - `Content-Type: application/json`
- **Body** (raw JSON):
```json
{
  "buyer": "0xb19094a082Baf95AAEb8A91F1D83D5C3028d4222",
  "beneficiary": "0xb19094a082Baf95AAEb8A91F1D83D5C3028d4222",
  "paymentToken": "0x0000000000000000000000000000000000000000",
  "usdAmount": 1000,
  "userId": "0xb19094a082Baf95AAEb8A91F1D83D5C3028d4222"
}
```

### Response:
```json
{
  "voucher": {
    "buyer": "0xb19094a082Baf95AAEb8A91F1D83D5C3028d4222",
    "beneficiary": "0xb19094a082Baf95AAEb8A91F1D83D5C3028d4222",
    "paymentToken": "0x0000000000000000000000000000000000000000",
    "usdLimit": "1000000000000000000000",
    "nonce": 0,
    "deadline": 1705324800,
    "presale": "0x1234567890123456789012345678901234567890"
  },
  "signature": "0x1234567890abcdef...",
  "nonce": 0,
  "deadline": 1705324800
}
```

---

## 4. Health Check

**GET** `/api/health`

### Postman Setup:
- **Method**: `GET`
- **URL**: `http://localhost:3000/api/health`

### Response:
```json
{
  "status": "OK",
  "timestamp": "2024-01-15T10:30:00.000Z"
}
```

---

## 5. Server Config Check

**GET** `/api/config`

### Postman Setup:
- **Method**: `GET`
- **URL**: `http://localhost:3000/api/config`

### Response:
```json
{
  "hasBaseUrl": true,
  "hasAppToken": true,
  "hasSecretKey": true,
  "baseUrl": "https://api.sumsub.com",
  "appTokenLength": 61,
  "secretKeyLength": 32,
  "appTokenPreview": "sbx:IwHB...",
  "secretKeyPreview": "zczQlyGA..."
}
```

---

## Troubleshooting

### Common Issues:

1. **Connection Refused**
   - Make sure backend server is running on port 3000
   - Check: `http://localhost:3000/api/health`

2. **404 Not Found**
   - Verify the URL path is correct
   - Make sure no trailing slashes

3. **500 Internal Server Error**
   - Check backend console for error messages
   - Verify environment variables are set correctly

4. **CORS Errors**
   - Should not happen as CORS is enabled for all origins
   - If issues persist, check server logs

### Testing Workflow:

1. ✅ Start backend: `cd backened && npm start`
2. ✅ Test health: `GET /api/health`
3. ✅ Test config: `GET /api/config`
4. ✅ Start verification: `POST /api/verify/start`
5. ✅ Check status: `GET /api/verify/status/{userId}`
6. ✅ Generate voucher: `POST /api/presale/voucher`

