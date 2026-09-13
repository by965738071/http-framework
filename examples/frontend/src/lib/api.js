const BASE = '/api';

async function request(method, path, body = null) {
  const opts = {
    method,
    headers: {},
    credentials: 'same-origin',
  };

  if (body) {
    if (body instanceof FormData) {
      opts.body = body;
    } else {
      opts.headers['Content-Type'] = 'application/json';
      opts.body = JSON.stringify(body);
    }
  }

  const res = await fetch(`${BASE}${path}`, opts);
  const data = await res.json().catch(() => null);

  if (!res.ok) {
    const msg = (data && (data.message || data.error)) || `Request failed (${res.status})`;
    throw new Error(msg);
  }

  // RBAC 后端统一返回 {"code":"OK","data":...}，解一层再给页面用。
  return data && data.code === 'OK' && 'data' in data ? data.data : data;
}

export const api = {
  // Auth（RBAC /api/v1）
  login: (username, password) => request('POST', '/v1/auth/login', { username, password }),
  // 注册走旧 demo（/api/register，form 格式，独立于 RBAC 数据库）。
  register: (data) => request('POST', '/register', data),
  logout: () => request('POST', '/v1/auth/logout'),
  me: () => request('GET', '/v1/auth/me'),

  // Users（RBAC /api/v1）
  getUsers: () => request('GET', '/v1/users'),
  getUser: (id) => request('GET', `/v1/users/${id}`),
  createUser: (data) => request('POST', '/v1/users', data),
  updateUser: (id, data) => request('PUT', `/v1/users/${id}`, data),
  deleteUser: (id) => request('DELETE', `/v1/users/${id}`),

  // Devices（/api/devices，旧 admin demo，JSON body，需 sid cookie）
  getDevices: (params = {}) => {
    const qs = new URLSearchParams(params).toString();
    return request('GET', `/devices${qs ? '?' + qs : ''}`);
  },
  getDevice: (id) => request('GET', `/devices/${id}`),
  createDevice: (data) => request('POST', '/devices', data),
  updateDevice: (id, data) => request('PUT', `/devices/${id}`, data),
  deleteDevice: (id) => request('DELETE', `/devices/${id}`),
};
