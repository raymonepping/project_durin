// src/seed-data.js — deterministic demo dataset.
//
// Every value below that is "sensitive" (iban, tax_id, payment_info, document
// payloads) is sent through the Data Trust Gateway on seed and lands in
// PostgreSQL only as Vault Transit ciphertext. RESTRICTED documents are
// protected under durin-<tenant>-restricted and need break glass to recover.

export const customerSeed = [
  { slug: 'acme', customers: [
    { name: 'Alice Smith',   company: 'ACME Corporation', country: 'NL', iban: 'NL91ABNA0417164300',        tax_id: 'NL123456789B01',  payment_info: 'SEPA Direct Debit - NL91ABNA' },
    { name: 'Bob Johnson',   company: 'ACME Corporation', country: 'NL', iban: 'NL13TEST0123456789',        tax_id: 'NL987654321B01',  payment_info: 'MASTERCARD-5500-1111' },
    { name: 'Carol White',   company: 'ACME Inc.',        country: 'BE', iban: 'BE68539007547034',          tax_id: 'BE0123456789',    payment_info: 'AMEX-378282-246310005' },
    { name: 'David Brown',   company: 'ACME Corp.',       country: 'DE', iban: 'DE89370400440532013000',    tax_id: 'DE123456789',     payment_info: 'VISA-4012-8888-8888' },
    { name: 'Eve Martinez',  company: 'ACME Ltd.',        country: 'FR', iban: 'FR7614508710004000000000000', tax_id: 'FR12345678901', payment_info: 'CB-4111-1111-1111' },
    { name: 'Frank Wilson',  company: 'ACME BV',          country: 'NL', iban: 'NL20INGB0001234567',        tax_id: 'NL111222333B01',  payment_info: 'VISA-4444-3333-2222' },
  ]},
  { slug: 'globex', customers: [
    { name: 'Grace Lee',     company: 'Globex Inc.',  country: 'US', iban: 'US12345678901234',     tax_id: '12-3456789',   payment_info: 'VISA-4916-3813-9912' },
    { name: 'Hank Kim',      company: 'Globex Inc.',  country: 'KR', iban: 'KR1234567890123456',   tax_id: '123-45-67890', payment_info: 'KAKAOPAY-88888888' },
    { name: 'Iris Park',     company: 'Globex Co.',   country: 'US', iban: 'US98765432109876',     tax_id: '98-7654321',   payment_info: 'AMEX-371449-635398431' },
    { name: 'Jack Chen',     company: 'Globex Ltd.',  country: 'SG', iban: 'SG12345678901234',     tax_id: 'S1234567D',    payment_info: 'PAYNOW-S1234567D' },
    { name: 'Kate Davis',    company: 'Globex LLC',   country: 'US', iban: 'US11122233344455',     tax_id: '11-2233445',   payment_info: 'DISCOVER-6011-0009-9013' },
  ]},
  { slug: 'initech', customers: [
    { name: 'Liam Taylor',   company: 'Initech Ltd.', country: 'GB', iban: 'GB29NWBK60161331926819', tax_id: 'GB123456789',       payment_info: 'VISA-4929-4212-3456' },
    { name: 'Mia Walker',    company: 'Initech Ltd.', country: 'GB', iban: 'GB29NWBK60161331999999', tax_id: 'GB987654321',       payment_info: 'MASTERCARD-5105-1051' },
    { name: 'Noah Harris',   company: 'Initech plc',  country: 'IE', iban: 'IE29AIBK93115212345678', tax_id: 'IE1234567T',        payment_info: 'VISA-4111-1111-1111' },
    { name: 'Olivia Clark',  company: 'Initech AG',   country: 'CH', iban: 'CH5604835012345678009',  tax_id: 'CHE-123.456.789',   payment_info: 'POSTCARD-0001-2345-6789' },
    { name: 'Paul Adams',    company: 'Initech BV',   country: 'NL', iban: 'NL91ABNA0417100000',    tax_id: 'NL000111222B02',    payment_info: 'VISA-4012-3456-7890' },
  ]},
];

export const documentSeed = [
  { slug: 'acme', docs: [
    {
      name: 'Customer Contract — Alice Smith',
      content_type: 'application/pdf',
      classification: 'CONFIDENTIAL',
      customer: 'Alice Smith',
      created_by: 'contracts@acme.com',
      payload: 'CONTRACT v1.0\nParties: ACME Corporation and Alice Smith\nDate: 2026-01-15\nScope: Data processing agreement under GDPR Art. 28\nIBAN authorisation: NL91ABNA0417164300\nSignature: [REDACTED]\nThis contract governs the processing of personal data including payment information and tax identifiers as defined in Schedule A.',
    },
    {
      name: 'Q1 2026 Financial Report',
      content_type: 'application/pdf',
      classification: 'RESTRICTED',
      customer: null,
      created_by: 'finance@acme.com',
      payload: 'ACME CORPORATION — CONFIDENTIAL FINANCIAL REPORT Q1 2026\nRevenue: €4,820,000\nOperating costs: €3,150,000\nEBITDA: €1,670,000\nCustomer payment defaults: 3 accounts (total exposure €42,500)\nIBAN reconciliation status: COMPLETE\nTax filing status: SUBMITTED — NL123456789B01',
    },
    {
      name: 'GDPR Data Processing Agreement — Carol White',
      content_type: 'application/pdf',
      classification: 'CONFIDENTIAL',
      customer: 'Carol White',
      created_by: 'legal@acme.com',
      payload: 'DATA PROCESSING AGREEMENT\nController: ACME Inc.\nProcessor: Carol White (BE0123456789)\nPurpose: Cross-border payment processing\nLegal basis: GDPR Art. 6(1)(b)\nData categories: IBAN, tax identification number, payment method\nRetention: 7 years per Belgian tax law\nIBAN: BE68539007547034',
    },
    {
      name: 'Production Incident Report #1842',
      content_type: 'text/markdown',
      classification: 'RESTRICTED',
      customer: null,
      created_by: 'security@acme.com',
      payload: 'INCIDENT #1842 — RESTRICTED\nSeverity: SEV-1\nDetected: 2026-03-14 02:17 UTC\nSummary: Anomalous bulk export attempt against the payments database from a compromised CI runner.\nAffected records: 1,204 customer rows (ciphertext only — no Transit authority on the runner)\nContainment: runner credentials revoked, Vault AppRole secret-id rotated, DB lease revoked\nOpen action: forensic review of payment reconciliation job (owner: security-admin)',
    },
  ]},
  { slug: 'globex', docs: [
    {
      name: 'Service Level Agreement — Grace Lee',
      content_type: 'application/pdf',
      classification: 'CONFIDENTIAL',
      customer: 'Grace Lee',
      created_by: 'ops@globex.com',
      payload: 'SERVICE LEVEL AGREEMENT\nProvider: Globex Inc.\nClient: Grace Lee (SSN: 12-3456789)\nEffective: 2026-02-01\nPayment terms: Net 30 via VISA-4916-3813-9912\nUptime commitment: 99.9%\nThis document contains personal financial identifiers and is classified CONFIDENTIAL under Globex Information Security Policy v3.2.',
    },
    {
      name: 'Asia-Pacific Expansion Report 2026',
      content_type: 'application/pdf',
      classification: 'RESTRICTED',
      customer: null,
      created_by: 'strategy@globex.com',
      payload: 'GLOBEX INC — RESTRICTED — APAC EXPANSION REPORT 2026\nMarkets targeted: KR, SG, JP\nProjected revenue uplift: USD 12.4M\nKey accounts: Hank Kim (KR1234567890123456), Jack Chen (SG12345678901234)\nTax exposure: KR 123-45-67890, SG S1234567D\nPayment infrastructure: KAKAOPAY, PAYNOW integration required Q3 2026',
    },
    {
      name: 'Compliance Certificate — Iris Park',
      content_type: 'application/pdf',
      classification: 'INTERNAL',
      customer: 'Iris Park',
      created_by: 'compliance@globex.com',
      payload: 'COMPLIANCE CERTIFICATE\nIssued to: Iris Park\nTax ID: 98-7654321\nPayment method on file: AMEX-371449-635398431\nKYC status: VERIFIED 2026-01-10\nAML screening: CLEAR\nThis certificate confirms that the above customer has completed Globex compliance onboarding as required by US FinCEN regulations.',
    },
  ]},
  { slug: 'initech', docs: [
    {
      name: 'Employment Contract — Liam Taylor',
      content_type: 'application/pdf',
      classification: 'CONFIDENTIAL',
      customer: 'Liam Taylor',
      created_by: 'hr@initech.com',
      payload: 'EMPLOYMENT CONTRACT\nEmployer: Initech Ltd.\nEmployee: Liam Taylor\nNational Insurance: GB123456789\nSalary payment IBAN: GB29NWBK60161331926819\nStart date: 2026-03-01\nPosition: Senior Engineer\nPayment method: BACS direct to VISA-4929-4212-3456\nThis document is strictly confidential and subject to UK GDPR.',
    },
    {
      name: 'Vendor Invoice — Olivia Clark',
      content_type: 'application/pdf',
      classification: 'INTERNAL',
      customer: 'Olivia Clark',
      created_by: 'finance@initech.com',
      payload: 'VENDOR INVOICE #INV-2026-0042\nVendor: Olivia Clark / Initech AG\nVAT: CHE-123.456.789\nPayment IBAN: CH5604835012345678009\nPayment method: PostCard 0001-2345-6789\nAmount: CHF 8,400.00\nDue: 2026-04-15\nRemittance to Swiss IBAN only — no third-party transfers authorised.',
    },
    {
      name: 'Board Security Briefing — Q1 2026',
      content_type: 'text/markdown',
      classification: 'RESTRICTED',
      customer: null,
      created_by: 'ciso@initech.com',
      payload: 'INITECH LTD — RESTRICTED — BOARD SECURITY BRIEFING Q1 2026\nTop risk: third-party payroll processor access to employee IBANs (GB29NWBK60161331926819 et al.)\nMitigation: field-level Transit encryption, per-tenant keys, break-glass for HR investigations\nPending decision: 90-day key rotation with mandatory rewrap\nPen-test finding PT-2026-07: database snapshot exfiltration yields ciphertext only',
    },
  ]},
];
