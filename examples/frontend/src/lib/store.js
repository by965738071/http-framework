import { writable } from 'svelte/store';

export const currentUser = writable(null);
export const isAuthenticated = writable(false);
export const currentPage = writable('login');
export const toast = writable({ show: false, message: '', type: 'info' });

export function showToast(message, type = 'info') {
  toast.set({ show: true, message, type });
  setTimeout(() => toast.set({ show: false, message: '', type: 'info' }), 3000);
}

export function navigate(page) {
  currentPage.set(page);
  window.location.hash = page;
}

// 初始化路由
export function initRouter() {
  const hash = window.location.hash.slice(1) || 'login';
  currentPage.set(hash);
  
  window.addEventListener('hashchange', () => {
    const page = window.location.hash.slice(1) || 'login';
    currentPage.set(page);
  });
}
