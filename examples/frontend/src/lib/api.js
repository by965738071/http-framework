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
  const data = await res.json();
  
  if (!res.ok) {
    throw new Error(data.error || data.message || 'Request failed');
  }
  
  return data;
}

export const api = {
  // Auth
  login: (username, password) => request('POST', '/login', { username, password }),
  register: (data) => request('POST', '/register', data),
  logout: () => request('POST', '/logout'),
  me: () => request('GET', '/me'),
  
  // Users
  getUsers: () => request('GET', '/users'),
  getUser: (id) => request('GET', `/users/${id}`),
  createUser: (data) => request('POST', '/users', data),
  updateUser: (id, data) => request('PUT', `/users/${id}`, data),
  deleteUser: (id) => request('DELETE', `/users/${id}`),
  
  // Devices
  getDevices: (params = {}) => {
    const qs = new URLSearchParams(params).toString();
    return request('GET', `/devices${qs ? '?' + qs : ''}`);
  },
  getDevice: (id) => request('GET', `/devices/${id}`),
  createDevice: (data) => request('POST', '/devices', data),
  updateDevice: (id, data) => request('PUT', `/devices/${id}`, data),
  deleteDevice: (id) => request('DELETE', `/devices/${id}`),
};
