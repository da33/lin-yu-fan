/**
 * 學生端（試算表一列）→ 學校早鳥系統（saip.vnu.edu.tw/RevEnt）欄位對應
 *
 * 只做資料轉換，不碰網頁。回傳 { form, problems }：
 *   form     = 要填進學校表單的值（key 是表單欄位的 name）
 *   problems = 無法自動處理的原因；有內容就不會送出，改標「需人工確認」或「不適用」
 * 欄位與選項來自 inspect.mjs 的偵察結果（116 學年度版本）。
 */
import fs from 'node:fs';

const SCHOOLS = JSON.parse(fs.readFileSync(new URL('./schools.json', import.meta.url), 'utf8'));

export const LIMITS = { TX_Idno: 10, TX_Cname: 8, TX_bef_dept_name: 15, TX_bef_class_name: 15, TX_phone: 10, TX_VnuReferee: 4, TX_BefReFeree: 4 };

export const TEST_GROUPS = [
  '01 機械群', '02 動力機械群', '03 電機與電子群電機類', '04 電機與電子群資電類', '05 化工群', '06 土木與建築群',
  '07 設計群', '08 工程與管理類', '09 商業與管理群', '10 衛生與護理類', '11 食品群', '12 家政群幼保類',
  '13 家政群生活應用類', '14 農業群', '15 外語群英語類', '16 外語群日語類', '17 餐旅群', '18 海事群', '19 水產群',
  '20 藝術群影視類', '21未考統測', '22報考學測', '23進修部',
];

export const DEPARTMENTS = [
  '企業管理系', '商業設計系', '化妝品應用與管理系', '資訊工程系', '觀光與休閒事業管理系', '餐飲管理系',
  '行銷與流通管理系', '航空暨運輸服務管理系', '航空光機電系', '時尚造型設計暨表演藝術系 時尚造型組',
  '時尚造型設計暨表演藝術系 表演藝術組', '車輛工程系', '精密機械與工業工程系', '室內設計與營建科技系', '電機工程系',
];

export const INFO_FROM = ['1萬能科大推薦人', '2高中職推薦人', '3親友推薦', '4萬能官網', '5-FB', '6-IG', '7-LINE@'];
// 學生端（index.html 的 CONFIG.sources）顯示的文字 → 學校選項
const INFO_FROM_ALIASES = {
  萬能科大老師推薦: INFO_FROM[0], 高中職老師推薦: INFO_FROM[1], 親友推薦: INFO_FROM[2], 萬能官網: INFO_FROM[3],
  Facebook: INFO_FROM[4], Instagram: INFO_FROM[5], 'LINE 官方帳號': INFO_FROM[6],
};

const SPEC_SKILLS = { 乙級證照: '1', '技能(藝)比賽獲獎': '2', 全國性比賽獲獎: '3' };

const ID_MAP = { A: 10, B: 11, C: 12, D: 13, E: 14, F: 15, G: 16, H: 17, I: 34, J: 18, K: 19, L: 20, M: 21, N: 22, O: 35, P: 23, Q: 24, R: 25, S: 26, T: 27, U: 28, V: 29, W: 32, X: 30, Y: 31, Z: 33 };
export function validTwId(s) {
  if (/^[A-Z]{2}\d{8}$/.test(s)) return true; // 舊式居留證號
  if (!/^[A-Z][1289]\d{8}$/.test(s)) return false;
  const n = ID_MAP[s[0]];
  let sum = Math.floor(n / 10) + (n % 10) * 9;
  [8, 7, 6, 5, 4, 3, 2, 1].forEach((w, i) => { sum += Number(s[i + 1]) * w; });
  return (sum + Number(s[9])) % 10 === 0;
}

// 學生常用的簡稱 → 學校系統裡的名稱
const ALIASES = {
  中壢高中: '中央大學附屬中壢高中', 桃園農工: '北科大附屬桃園農工', 莊敬高職: '莊敬工家', 中山女高: '中山女中',
  北大高中: '北大高級中學', 崇光高中: '崇光女中', 強恕高中: '強恕中學', 臺北育達: '台北育達高中', 育達高職: '台北育達高中',
  建中: '建國中學', 北一女: '北一女中', 師大附中: '師大附中', 國光高中: '中山大學附屬國光高中', 高餐附中: '高餐大附屬餐旅中學',
};

// 校名比對：去掉「國立、市立、臺/台」等差異後比較
const normSchool = s => String(s || '').normalize('NFKC').replace(/\s/g, '').replace(/台/g, '臺')
  .replace(/^(國立|市立|縣立|私立|臺北市立|新北市立|桃園市立|臺中市立|臺南市立|高雄市立)/, '')
  .replace(/高級中學$/, '高中');

/** 名稱可以帶縣市，例如「大同高中（苗栗縣）」；同名學校不只一所時一定要帶縣市 */
export function findSchool(input) {
  const raw = String(input || '').trim();
  const m = raw.match(/^(.+?)[（(](.+?)[）)]$/);
  const name = m ? m[1] : raw;
  const county = m ? m[2].replace(/台/g, '臺') : null;
  if (!name) return null;
  const all = Object.entries(SCHOOLS)
    .filter(([c]) => !county || c === county)
    .flatMap(([c, list]) => list.map(s => ({ county: c, school: s })));
  const target = normSchool(ALIASES[name] || ALIASES[normSchool(name)] || name);
  const exact = all.filter(x => normSchool(x.school) === target);
  if (exact.length === 1) return exact[0];
  if (exact.length > 1) return null; // 同名學校，沒有縣市就不猜
  // 只差幾個字（例如多了「附屬」前綴）：唯一一所包含它的才採用
  const loose = all.filter(x => normSchool(x.school).includes(target) || (target.length >= 4 && target.includes(normSchool(x.school))));
  return loose.length === 1 ? loose[0] : null;
}

// 年級 → 畢業年：學校系統只收 116（今年高三）、115、114前
function graduYear(grade) {
  const g = String(grade || '');
  if (!g.trim()) return '116'; // App 沒問年級：比照學校系統的預設值（今年高三）
  if (/高三|116/.test(g)) return '116';
  if (/115/.test(g)) return '115';
  if (/114|以前|更早/.test(g)) return '114前';
  return null;
}

const pickOption = (value, options) => {
  const v = String(value || '').trim();
  if (!v) return '';
  return options.find(o => o === v) || options.find(o => o.replace(/^\d+\s*-?/, '') === v.replace(/^\d+\s*-?/, '')) || null;
};

export function mapRow(r) {
  const problems = [];
  const form = {};
  const need = (key, value, label) => {
    const v = String(value || '').trim();
    if (!v) { problems.push(`${label}沒填`); return ''; }
    if (LIMITS[key] && v.length > LIMITS[key]) problems.push(`${label}超過 ${LIMITS[key]} 個字`);
    return v;
  };

  const idno = String(r['身分證字號'] || '').normalize('NFKC').toUpperCase().replace(/\s/g, '');
  form.TX_Idno = need('TX_Idno', idno, '身分證字號');
  if (idno && !validTwId(idno)) problems.push('身分證字號檢查碼不對');

  form.TX_Cname = need('TX_Cname', r['姓名'], '姓名');

  const school = findSchool(r['就讀學校']);
  const sameName = Object.entries(SCHOOLS).filter(([, list]) => list.includes(String(r['就讀學校'] || '').trim())).map(([c]) => c);
  if (!school) {
    problems.push(sameName.length > 1
      ? `「${r['就讀學校']}」有 ${sameName.length} 所（${sameName.join('、')}），要確認是哪個縣市`
      : `學校「${r['就讀學校'] || ''}」在學校系統的名單裡找不到`);
  }
  else { form.LB_District = school.county; form.LB_DistrictSchoolName = school.school; }

  form.TX_bef_dept_name = need('TX_bef_dept_name', r['科別'], '科別');
  form.TX_bef_class_name = need('TX_bef_class_name', r['班級'], '班級');

  const year = graduYear(r['年級']);
  if (!year) problems.push(`年級「${r['年級'] || ''}」不在這次早鳥範圍（只收 116 年畢業或已畢業）`);
  else form.LB_GraduYear = year;

  const phone = String(r['手機'] || '').replace(/\D/g, '');
  form.TX_phone = need('TX_phone', phone, '手機');
  if (phone && !/^09\d{8}$/.test(phone)) problems.push('手機不是 09 開頭的 10 碼');

  form.TX_LineID = String(r['LineID'] || '').trim();

  const group = pickOption(r['統測群類'], TEST_GROUPS);
  if (!group) problems.push(group === '' ? '統測群類沒填' : `統測群類「${r['統測群類']}」對不上學校選項`);
  else form.LB_TestGroup = group;

  const wishes = String(r['有興趣的系'] || '').split(/[、,，]/).map(s => s.trim()).filter(Boolean);
  const mapped = wishes.map(w => pickOption(w, DEPARTMENTS));
  if (!wishes.length) problems.push('第一志願沒填');
  mapped.forEach((m, i) => { if (!m) problems.push(`志願「${wishes[i]}」對不上學校系所選項`); });
  [...new Set(mapped.filter(Boolean))].slice(0, 3).forEach((d, i) => { form['LB_DeptDesire' + (i + 1)] = d; });

  const needs = String(r['工讀住宿'] || '');
  form.LB_ReqPartTime = /工讀|兩個/.test(needs) ? 'Y' : 'N';
  form.LB_Domitory = /住宿|兩個/.test(needs) ? 'Y' : 'N';

  form.CBL_SpecSkills = String(r['特殊表現'] || '').split(/[、,，]/).map(s => SPEC_SKILLS[s.trim()]).filter(Boolean);

  form.TX_VnuReferee = String(r['招生老師'] || '').trim().slice(0, LIMITS.TX_VnuReferee);
  form.TX_BefReFeree = String(r['班導師'] || '').trim().slice(0, LIMITS.TX_BefReFeree);

  // 掃招生老師或活動 QR Code 進來的 → 萬能科大推薦人；否則用學生自己選的管道
  form.LB_InfoFrom = (r['招生老師'] || r['活動來源']) ? INFO_FROM[0] : (INFO_FROM_ALIASES[String(r['得知管道'] || '').trim()] || pickOption(r['得知管道'], INFO_FROM) || INFO_FROM[0]);

  if (r['個資同意'] !== '同意') problems.push('沒有個資同意');
  form.CKB_Iagree = r['個資同意'] === '同意';

  // 不在早鳥範圍的（高一、高二…）標「不適用」，其他問題標「需人工確認」
  const notEligible = !year && problems.length === 1;
  return { form, problems, notEligible };
}
