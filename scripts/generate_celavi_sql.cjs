const fs = require('fs');

const celaviCompanyId = '22222222-2222-2222-2222-222222222222';
const celaviLoc1 = '2b2b2b2b-2b2b-2b2b-2b2b-2b2b2b2b2b21'; // Celavi Dist Center
const celaviLoc2 = '2b2b2b2b-2b2b-2b2b-2b2b-2b2b2b2b2b22'; // Celavi North
const celaviLoc3 = '2b2b2b2b-2b2b-2b2b-2b2b-2b2b2b2b2b23'; // Celavi South
const celaviBin1 = '2b2b2b2b-2b2b-2b2b-2b2b-2b2b2b2b2b2a';
const celaviBin2 = '2b2b2b2b-2b2b-2b2b-2b2b-2b2b2b2b2b2b';
const celaviBin3 = '2b2b2b2b-2b2b-2b2b-2b2b-2b2b2b2b2b2c';

const lines = fs.readFileSync('scripts/celavi_products.tsv', 'utf-8').trim().split('\n').slice(0, 1);

let productsSql = `INSERT INTO products (id, company_id, name, sku, base_unit_id, default_sale_unit_id) VALUES\n`;
let unitsSql = `INSERT INTO product_units (id, company_id, product_id, unit_name, unit_code, conversion_to_base, is_base_unit, is_default_sale_unit, is_active, quantity_scale, quantity_step, max_transaction_quantity) VALUES\n`;
let balancesSql = `INSERT INTO inventory_balances (company_id, location_id, bin_id, product_id, inventory_status, on_hand_base_qty, reserved_base_qty) VALUES\n`;

const products = [];
const units = [];
const balances = [];

lines.forEach((line, i) => {
  const parts = line.split('\t');
  if (parts.length < 5) return;
  const no = parts[0];
  const name = parts[1].replace(/'/g, "''");
  const unit = parts[2].replace(/'/g, "''");
  const qty = parseInt(parts[3], 10);
  const padStart = (str, len, char) => (char.repeat(len) + str).slice(-len);
  const pId = `44444444-2222-2222-2222-` + padStart((i + 1).toString(), 12, '0');
  const uId = `55555555-2222-2222-2222-` + padStart((i + 1).toString(), 12, '0');
  
  products.push(`('${pId}', '${celaviCompanyId}', '${name}', 'CEL-${padStart(no, 3, '0')}', '${uId}', '${uId}')`);
  units.push(`('${uId}', '${celaviCompanyId}', '${pId}', '${unit}', 'unit', 1, true, true, true, 0, 1, 1000000)`);
  
  // Apportion qty across the 3 locations
  let q1 = Math.floor(qty * 0.5);
  let q2 = Math.floor(qty * 0.25);
  let q3 = qty - q1 - q2;
  
  if (q1 > 0) balances.push(`('${celaviCompanyId}', '${celaviLoc1}', '${celaviBin1}', '${pId}', 'AVAILABLE', ${q1}, 0)`);
  if (q2 > 0) balances.push(`('${celaviCompanyId}', '${celaviLoc2}', '${celaviBin2}', '${pId}', 'AVAILABLE', ${q2}, 0)`);
  if (q3 > 0) balances.push(`('${celaviCompanyId}', '${celaviLoc3}', '${celaviBin3}', '${pId}', 'AVAILABLE', ${q3}, 0)`);
});

const sql = `
-- Celavi Pharmacy Products
${productsSql}
${products.join(',\n')};

-- Celavi Pharmacy Units
${unitsSql}
${units.join(',\n')};

-- Celavi Pharmacy Balances
${balancesSql}
${balances.join(',\n')};

COMMIT;
`;

fs.writeFileSync('scripts/celavi_inserts.sql', sql);
console.log('Done generating celavi_inserts.sql');
