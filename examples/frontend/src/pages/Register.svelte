<script>
  import { navigate, showToast } from '../lib/store.js';
  import { api } from '../lib/api.js';

  let username = '';
  let email = '';
  let password = '';
  let confirmPassword = '';
  let error = '';
  let loading = false;

  async function handleRegister() {
    error = '';
    if (password !== confirmPassword) {
      error = '两次密码不一致';
      return;
    }
    loading = true;
    try {
      await api.register({ username, email, password });
      showToast('注册成功，请登录', 'success');
      navigate('login');
    } catch (e) {
      error = e.message || '注册失败';
    } finally {
      loading = false;
    }
  }
</script>

<div class="min-h-screen flex items-center justify-center bg-gradient-to-br from-blue-50 to-indigo-100">
  <div class="bg-white rounded-2xl shadow-xl p-8 w-full max-w-md">
    <div class="text-center mb-8">
      <h1 class="text-3xl font-bold text-gray-900">创建账号</h1>
      <p class="text-gray-500 mt-2">注册新用户</p>
    </div>
    
    {#if error}
      <div class="mb-4 p-3 bg-red-50 border border-red-200 text-red-700 rounded-lg text-sm">{error}</div>
    {/if}
    
    <form on:submit|preventDefault={handleRegister} class="space-y-4">
      <div>
        <label class="block text-sm font-medium text-gray-700 mb-1">用户名</label>
        <input type="text" bind:value={username} required
          class="w-full px-4 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-transparent" />
      </div>
      <div>
        <label class="block text-sm font-medium text-gray-700 mb-1">邮箱</label>
        <input type="email" bind:value={email} required
          class="w-full px-4 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-transparent" />
      </div>
      <div>
        <label class="block text-sm font-medium text-gray-700 mb-1">密码</label>
        <input type="password" bind:value={password} required
          class="w-full px-4 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-transparent" />
      </div>
      <div>
        <label class="block text-sm font-medium text-gray-700 mb-1">确认密码</label>
        <input type="password" bind:value={confirmPassword} required
          class="w-full px-4 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-transparent" />
      </div>
      <button type="submit" disabled={loading}
        class="w-full py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg font-medium disabled:opacity-50">
        {loading ? '注册中...' : '注册'}
      </button>
    </form>
    
    <p class="text-center mt-4 text-sm text-gray-500">
      已有账号？<button class="text-blue-600 hover:underline" on:click={() => navigate('login')}>登录</button>
    </p>
  </div>
</div>
