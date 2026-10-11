(() => {
  const config = window.SUPABASE_CONFIG;
  const sdk = window.supabase;
  const app = document.querySelector('#app');
  const queueLabel = count => count === 1 ? '1 person' : `${count} people`;
  let client;
  let realtime;
  let currentProfile;
  let isReady = false;
  const localStaffView = window.staff;
  const localAdminView = window.admin;
  const localDrawBell = window.drawBell;

  const fail = (error, action) => {
    console.error(`Supabase ${action} failed:`, error);
    toast(`${action} failed. Check the connection and try again.`);
  };
  const requireClient = () => {
    if (!client) throw new Error('Supabase configuration or SDK is unavailable');
    return client;
  };
  const toMenuItem = (row, index) => ({
    id: parseInt(row.id.replace(/-/g, '').slice(0, 13), 16) || index + 1,
    backendId: row.id,
    name: row.name,
    cat: row.category,
    desc: row.description,
    price: Number(row.price),
    emoji: row.emoji,
    veg: row.is_vegetarian,
    prep: row.prep_minutes,
    pop: row.is_popular,
    avail: row.is_available,
    img: row.image_url || ''
  });
  const mapOrder = (row, itemRows, index) => ({
    id: index + 1,
    backendId: row.id,
    token: row.token,
    user: row.user_id,
    studentName: row.student_name,
    items: itemRows.filter(item => item.order_id === row.id).map(item => ({
      id: item.menu_item_id,
      name: item.item_name,
      price: Number(item.unit_price),
      qty: item.quantity
    })),
    total: Number(row.total),
    pay: row.payment_method,
    payStatus: row.payment_status,
    status: row.status,
    note: row.note,
    time: new Date(row.created_at).toLocaleString('en-IN', { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' }),
    createdAt: row.created_at
  });

  async function loadRemoteState() {
    const api = requireClient();
    const { data: authData, error: authError } = await api.auth.getUser();
    if (authError) throw authError;
    if (!authData.user) {
      currentProfile = null;
      S = seed();
      return;
    }
    const { data: profile, error: profileError } = await api
      .from('profiles')
      .select('id,display_name,phone,role,is_active')
      .eq('id', authData.user.id)
      .single();
    if (profileError) throw profileError;
    if (!profile.is_active) {
      await api.auth.signOut();
      currentProfile = null;
      setSess(null);
      go('/login');
      throw new Error('This account has been disabled. Contact the canteen administrator.');
    }
    currentProfile = { ...profile, email: authData.user.id, authEmail: authData.user.email };
    let savedCart = [];
    try {
      const cartValue = JSON.parse(localStorage.getItem(`scq_cart_${authData.user.id}`) || '[]');
      if (Array.isArray(cartValue)) {
        savedCart = cartValue.filter(entry =>
          Number.isSafeInteger(entry?.id) &&
          Number.isInteger(entry?.qty) &&
          entry.qty > 0 &&
          entry.qty <= 50
        );
      }
    } catch (error) {
      console.warn('Discarding invalid saved cart data:', error);
    }
    S = seed();
    S.carts[authData.user.id] = savedCart;
    S.users = [currentProfile];

    const [menuResult, categoryResult, orderResult, queueResult, favoriteResult, notificationResult] = await Promise.all([
      api.from('menu_items').select('id,name,category,description,price,emoji,is_vegetarian,prep_minutes,is_popular,is_available,image_url').eq('is_active', true).order('name'),
      api.from('menu_categories').select('name').order('name'),
      api.from('orders').select('id,token,user_id,student_name,status,note,payment_method,payment_status,total,created_at').order('created_at', { ascending: true }),
      api.rpc('get_queue_status'),
      api.from('favorites').select('menu_item_id').eq('user_id', authData.user.id),
      api.from('notifications').select('id,order_id,message,is_read,created_at').order('created_at', { ascending: false }).limit(50)
    ]);
    for (const result of [menuResult, categoryResult, orderResult, queueResult, favoriteResult, notificationResult]) {
      if (result.error) throw result.error;
    }
    S.menu = menuResult.data.map(toMenuItem);
    S.cats = categoryResult.data.map(category => category.name);
    S.queue = queueResult.data[0] || { walk_in_count: 0, active_preorders: 0, updated_at: null };
    const orderIds = orderResult.data.map(order => order.id);
    let itemRows = [];
    if (orderIds.length) {
      const { data, error } = await api.from('order_items').select('order_id,menu_item_id,item_name,unit_price,quantity').in('order_id', orderIds);
      if (error) throw error;
      itemRows = data;
    }
    S.orders = orderResult.data.map((row, index) => mapOrder(row, itemRows, index));
    S.notifs = notificationResult.data.map(row => ({
      id: row.id,
      to: currentProfile.id,
      text: row.message,
      order: S.orders.find(order => order.backendId === row.order_id)?.id,
      read: row.is_read,
      time: new Date(row.created_at).toLocaleTimeString('en-IN', { hour: '2-digit', minute: '2-digit' })
    }));
    S.orders.forEach(order => {
      if (!S.users.some(user => user.email === order.user)) {
        S.users.push({ email: order.user, name: order.studentName, role: 'student' });
      }
    });
    S.favs[currentProfile.id] = favoriteResult.data
      .map(favorite => S.menu.find(item => item.backendId === favorite.menu_item_id)?.id)
      .filter(Number.isFinite);
    S.users = S.users.map(user => user.email === currentProfile.id
      ? { ...user, email: currentProfile.id, name: currentProfile.display_name }
      : user);

    if (currentProfile.role === 'admin') {
      const { data: profiles, error } = await api.from('profiles').select('id,display_name,phone,role,is_active').order('display_name');
      if (error) throw error;
      S.users = profiles.map(user => ({ ...user, email: user.id, name: user.display_name }));
      S.userCount = profiles.filter(user => user.role === 'student').length;
    }
  }

  async function refresh() {
    try {
      await loadRemoteState();
      const page = location.hash.slice(2).split('/')[0];
      const roleHome = { student: 'home', staff: 'staff', admin: 'admin' }[currentProfile?.role];
      const allowedPages = {
        student: ['home', 'menu', 'cart', 'checkout', 'order', 'history'],
        staff: ['staff'],
        admin: ['admin']
      }[currentProfile?.role] || [];
      if (roleHome && page && !allowedPages.includes(page)) {
        go('/' + roleHome);
        return;
      }
      if (location.hash.slice(2).split('/')[0] === 'menu') drawGrid();
      render();
    } catch (error) {
      fail(error, 'Data refresh');
    }
  }

  function listen() {
    if (realtime) client.removeChannel(realtime);
    realtime = client.channel('smart-canteen-live')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'orders' }, refresh)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'order_items' }, refresh)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'menu_items' }, refresh)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'queue_state' }, refresh)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'notifications', filter: `user_id=eq.${currentProfile.id}` }, refresh)
      .on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'profiles', filter: `id=eq.${currentProfile.id}` }, refresh)
      .subscribe();
  }

  async function handleLogin() {
    const email = $('#em').value.trim().toLowerCase();
    const password = $('#pw').value;
    if (!email || !password) return toast('Enter your email and password');
    try {
      const { error } = await requireClient().auth.signInWithPassword({ email, password });
      if (error) throw error;
      await loadRemoteState();
      setSess(currentProfile.id);
      listen();
      go('/' + ({ student: 'home', staff: 'staff', admin: 'admin' }[currentProfile.role] || 'home'));
      render();
    } catch (error) {
      fail(error, 'Sign in');
    }
  }

  async function handleRegister() {
    const name = $('#n').value.trim();
    const email = $('#em').value.trim().toLowerCase();
    const phone = $('#ph').value.trim();
    const password = $('#pw').value;
    if (!name || !/^\S+@\S+\.\S+$/.test(email)) return toast('Enter a valid name and email');
    if (!/^\d{10}$/.test(phone)) return toast('Phone must be 10 digits');
    if (password.length < 8) return toast('Password needs at least 8 characters');
    if (password !== $('#pc').value) return toast('Passwords do not match');
    try {
      const { data, error } = await requireClient().auth.signUp({
        email,
        password,
        options: { data: { display_name: name, phone } }
      });
      if (error) throw error;
      if (!data.session) {
        toast('Check your email to confirm your account before signing in');
        go('/login');
        render();
        return;
      }
      await loadRemoteState();
      setSess(currentProfile.id);
      listen();
      go('/home');
      render();
    } catch (error) {
      fail(error, 'Registration');
    }
  }

  async function signOut() {
    try {
      const { error } = await requireClient().auth.signOut();
      if (error) throw error;
      currentProfile = null;
      setSess(null);
      if (realtime) client.removeChannel(realtime);
      go('/login');
      render();
    } catch (error) {
      fail(error, 'Sign out');
    }
  }

  async function placeLiveOrder() {
    if (!currentProfile || currentProfile.role !== 'student') return toast('Sign in with a student account to order');
    const items = cart().map(entry => {
      const menuItem = S.menu.find(item => item.id === entry.id);
      return menuItem && menuItem.backendId ? { id: menuItem.backendId, qty: entry.qty } : null;
    }).filter(Boolean);
    if (!items.length) return toast('Your cart has no available menu items');
    try {
      const { data: orderId, error } = await requireClient().rpc('place_order', {
        p_items: items,
        p_note: ($('#nt') || { value: '' }).value.trim().slice(0, 300)
      });
      if (error) throw error;
      S.carts[currentProfile.id] = [];
      await loadRemoteState();
      const order = S.orders.find(item => item.backendId === orderId);
      if (!order) throw new Error('Order was placed but could not be reloaded');
      JUST = order.id;
      go('/order/' + order.id);
      render();
    } catch (error) {
      fail(error, 'Order placement');
    }
  }

  async function updateWalkInQueue() {
    const count = Number($('#walk-in-count')?.value);
    if (!Number.isInteger(count) || count < 0 || count > 10000) return toast('Enter a whole number from 0 to 10000');
    try {
      const { error } = await requireClient().rpc('set_walk_in_queue_count', { p_count: count });
      if (error) throw error;
      await refresh();
      toast('Walk-in queue updated');
    } catch (error) {
      fail(error, 'Queue update');
    }
  }

  async function advanceLiveOrder(id) {
    const order = S.orders.find(item => String(item.id) === String(id));
    if (!order?.backendId) return toast('Order not found');
    try {
      const { error } = await requireClient().rpc('advance_order', { p_order_id: order.backendId });
      if (error) throw error;
      await refresh();
    } catch (error) {
      fail(error, 'Order update');
    }
  }

  async function toggleAvailability(id) {
    const item = S.menu.find(menuItem => String(menuItem.id) === String(id));
    if (!item?.backendId) return toast('Menu item not found');
    try {
      const { error } = await requireClient().rpc('set_menu_availability', {
        p_item_id: item.backendId,
        p_is_available: !item.avail
      });
      if (error) throw error;
      await refresh();
    } catch (error) {
      fail(error, 'Availability update');
    }
  }

  async function saveMenuItem(id, changes) {
    const old = S.menu.find(item => String(item.id) === String(id));
    const item = {
      id: old?.backendId || null,
      name: changes.name ?? old?.name,
      category: changes.category ?? old?.cat,
      description: changes.description ?? old?.desc ?? '',
      price: changes.price ?? old?.price,
      emoji: changes.emoji ?? old?.emoji ?? '🍽️',
      is_vegetarian: changes.is_vegetarian ?? old?.veg ?? true,
      prep_minutes: changes.prep_minutes ?? old?.prep ?? 5,
      is_popular: changes.is_popular ?? old?.pop ?? false,
      is_available: changes.is_available ?? old?.avail ?? true,
      image_url: changes.image_url ?? old?.img ?? null
    };
    try {
      const { error } = await requireClient().rpc('admin_save_menu_item', { p_item: item });
      if (error) throw error;
      return true;
    } catch (error) { throw error; }
  }

  async function importInitialMenu() {
    if (!currentProfile || currentProfile.role !== 'admin' || S.menu.length) return;
    if (!confirm('Import the website starter menu into Supabase? This adds menu items; it does not create orders or accounts.')) return;
    try {
      const { data: existing, error: existingError } = await requireClient()
        .from('menu_items').select('name,category');
      if (existingError) throw existingError;
      const names = new Set(existing.map(item => `${item.name.toLowerCase()}|${item.category.toLowerCase()}`));
      const items = seed().menu.filter(item => !names.has(`${item.name.toLowerCase()}|${item.cat.toLowerCase()}`));
      for (let start = 0; start < items.length; start += 8) {
        await Promise.all(items.slice(start, start + 8).map(item => saveMenuItem(null, {
          name: item.name,
          category: item.cat,
          description: item.desc,
          price: item.price,
          emoji: item.emoji,
          is_vegetarian: item.veg,
          prep_minutes: item.prep,
          is_popular: item.pop,
          is_available: item.avail,
          image_url: null
        })));
      }
      await refresh();
      toast('Starter menu imported');
    } catch (error) {
      fail(error, 'Menu import');
    }
  }

  async function archiveMenuItem(id) {
    const item = S.menu.find(menuItem => String(menuItem.id) === String(id));
    if (!item?.backendId || !confirm(`Archive ${item.name} from the menu?`)) return;
    try {
      const { error } = await requireClient().rpc('admin_archive_menu_item', { p_item_id: item.backendId });
      if (error) throw error;
      await refresh();
    } catch (error) {
      fail(error, 'Menu archive');
    }
  }

  async function changeRole(id, role) {
    if (!['student', 'staff', 'admin'].includes(role)) return toast('Invalid account role');
    try {
      const { error } = await requireClient().rpc('set_user_role', { p_user_id: id, p_role: role });
      if (error) throw error;
      await refresh();
      toast('Account role updated');
    } catch (error) {
      fail(error, 'Role update');
    }
  }

  async function setProfileActive(id, isActive) {
    try {
      const { error } = await requireClient().rpc('admin_set_profile_active', {
        p_user_id: id,
        p_is_active: isActive
      });
      if (error) throw error;
      await refresh();
      toast(isActive ? 'Account enabled' : 'Account disabled');
    } catch (error) {
      fail(error, 'Account status update');
    }
  }

  async function inviteStaff() {
    const name = $('#staff-name').value.trim();
    const email = $('#staff-email').value.trim().toLowerCase();
    const phone = $('#staff-phone').value.trim();
    if (!name || !/^\S+@\S+\.\S+$/.test(email)) return toast('Enter a valid staff name and email');
    if (!/^\d{10}$/.test(phone)) return toast('Phone must be 10 digits');
    try {
      const { data, error } = await requireClient().functions.invoke('invite-staff', {
        body: { name, email, phone }
      });
      if (error) throw error;
      $('#staff-name').value = '';
      $('#staff-email').value = '';
      $('#staff-phone').value = '';
      await refresh();
      toast(data?.message || 'Staff invitation sent');
    } catch (error) {
      fail(error, 'Staff invitation');
    }
  }

  async function saveCategory(name) {
    const { error } = await requireClient().rpc('admin_save_category', { p_name: name });
    if (error) throw error;
    await refresh();
  }

  async function renameCategory(oldName, newName) {
    const name = newName.trim();
    if (!name) return toast('Enter a category name');
    try {
      const { error } = await requireClient().rpc('admin_rename_category', {
        p_old_name: oldName,
        p_new_name: name
      });
      if (error) throw error;
      await refresh();
      toast('Category renamed');
    } catch (error) {
      fail(error, 'Category update');
    }
  }

  async function deleteCategory(name) {
    if (!confirm(`Delete the empty category "${name}"?`)) return;
    try {
      const { error } = await requireClient().rpc('admin_delete_category', { p_name: name });
      if (error) throw error;
      await refresh();
      toast('Category deleted');
    } catch (error) {
      fail(error, 'Category deletion');
    }
  }

  async function cancelLiveOrder(id) {
    const order = S.orders.find(item => String(item.id) === String(id));
    if (!order?.backendId || !confirm(`Cancel order ${order.token}?`)) return;
    try {
      const { error } = await requireClient().rpc('admin_cancel_order', { p_order_id: order.backendId });
      if (error) throw error;
      await refresh();
      toast(`Order ${order.token} cancelled`);
    } catch (error) {
      fail(error, 'Order cancellation');
    }
  }

  async function uploadMenuPhoto(id, input) {
    const file = input.files?.[0];
    if (!file) return;
    if (!['image/jpeg', 'image/png', 'image/webp'].includes(file.type) || file.size > 5 * 1024 * 1024) {
      input.value = '';
      return toast('Choose a JPG, PNG, or WebP image under 5 MB');
    }
    const item = S.menu.find(menuItem => String(menuItem.id) === String(id));
    if (!item?.backendId) return toast('Save this menu item before uploading its photo');
    try {
      const image = await new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onerror = () => reject(new Error('Could not read the image'));
        reader.onload = () => {
          const source = new Image();
          source.onerror = () => reject(new Error('Image file could not be decoded'));
          source.onload = () => resolve(source);
          source.src = reader.result;
        };
        reader.readAsDataURL(file);
      });
      const scale = Math.min(1, 1200 / image.width);
      const canvas = document.createElement('canvas');
      canvas.width = Math.round(image.width * scale);
      canvas.height = Math.round(image.height * scale);
      const context = canvas.getContext('2d');
      if (!context) throw new Error('Image processing is unavailable in this browser');
      context.drawImage(image, 0, 0, canvas.width, canvas.height);
      const blob = await new Promise(resolve => canvas.toBlob(resolve, 'image/webp', 0.82));
      if (!blob) throw new Error('Could not compress the image');
      const path = `${item.backendId}/${crypto.randomUUID()}.webp`;
      const storage = requireClient().storage.from('menu-images');
      const { error: uploadError } = await storage.upload(path, blob, { contentType: 'image/webp' });
      if (uploadError) throw uploadError;
      const { data } = storage.getPublicUrl(path);
      await saveMenuItem(id, { image_url: data.publicUrl });
      await refresh();
      toast('Menu photo uploaded');
    } catch (error) {
      fail(error, 'Menu photo upload');
    } finally {
      input.value = '';
    }
  }

  async function bulkUploadMenuPhotos(input) {
    const files = [...(input.files || [])];
    for (const file of files) {
      const name = file.name.replace(/\.[^.]+$/, '').replace(/[-_]+/g, ' ').toLowerCase();
      const item = S.menu.find(menuItem => menuItem.name.toLowerCase() === name);
      if (!item) {
        toast(`No menu item matches ${file.name}`);
        continue;
      }
      const proxyInput = { files: [file], value: '', };
      await uploadMenuPhoto(item.id, proxyInput);
    }
    input.value = '';
  }

  function renderCategories() {
    return `<h2>Admin panel</h2><div class="tabs">${['Overview','Food Items','Categories','Orders','Team'].map(tab => `<button class="${ATAB===tab?'on':''}" onclick="ATAB='${tab}';render()">${tab}</button>`).join('')}</div><div class="card"><h3>Add category</h3><div class="row"><input id="new-category" maxlength="60" placeholder="Category name"><button class="btn" onclick="saveCategoryFromForm()">Add category</button></div></div>${S.cats.length ? S.cats.map((category, index) => `<div class="card row sp"><input id="category-${index}" maxlength="60" value="${esc(category)}" aria-label="Category name"><div class="row"><button class="btn s" onclick="renameCategoryAt(${index})">Save</button><button class="btn r s" onclick="deleteCategoryAt(${index})">Delete</button></div></div>`).join('') : '<div class="card mu">No categories yet. Add a category or create one while adding a menu item.</div>'}`;
  }

  function renderLogin() {
    return hero() + `<div class="card auth"><h2>Sign in</h2><label>Email</label><input id="em" type="email" autocomplete="username"><label>Password</label><input id="pw" type="password" autocomplete="current-password"><div style="margin-top:14px"><button class="btn" style="width:100%" onclick="doLogin()">Sign in</button></div><p class="mu">New student? <a href="#/register">Create an account</a></p></div>`;
  }
  function renderRegister() {
    return `<div class="card auth"><h2>Student registration</h2><label>Name</label><input id="n" autocomplete="name"><label>Email</label><input id="em" type="email" autocomplete="email"><label>Phone</label><input id="ph" inputmode="numeric" maxlength="10" autocomplete="tel"><label>Password</label><input id="pw" type="password" autocomplete="new-password"><label>Confirm password</label><input id="pc" type="password" autocomplete="new-password"><button class="btn" style="width:100%;margin-top:14px" onclick="doReg()">Create student account</button><p class="mu">Already registered? <a href="#/login">Sign in</a></p></div>`;
  }

  window.doLogin = handleLogin;
  window.doReg = handleRegister;
  window.logout = signOut;
  window.login = renderLogin;
  window.register = renderRegister;
  window.pay = placeLiveOrder;
  window.adv = advanceLiveOrder;
  window.tog = toggleAvailability;
  window.addItem = async () => {
    try {
      await saveMenuItem(null, {
        name: $('#an').value.trim(),
        category: $('#ac').value,
        price: Number($('#ap').value),
        description: $('#ad').value.trim() || 'Freshly prepared',
        emoji: $('#ae').value.trim() || '🍽️',
        is_vegetarian: $('#av').value === '1',
        prep_minutes: 5
      });
      await refresh();
      toast('Menu item added');
    } catch (error) { fail(error, 'Menu update'); }
  };
  window.upd = async (id, key, value) => {
    try {
      const field = { cat: 'category', img: 'image_url' }[key] || key;
      await saveMenuItem(id, { [field]: value });
      await refresh();
      toast('Menu item updated');
    } catch (error) { fail(error, 'Menu update'); }
  };
  window.del = archiveMenuItem;
  window.setRole = changeRole;
  window.setProfileActive = setProfileActive;
  window.inviteStaff = inviteStaff;
  window.saveCategoryFromForm = async () => {
    const name = $('#new-category').value.trim();
    if (!name) return toast('Enter a category name');
    try {
      await saveCategory(name);
      toast('Category added');
    } catch (error) { fail(error, 'Category creation'); }
  };
  window.renameCategoryAt = index => {
    const input = $(`#category-${index}`);
    if (input) renameCategory(S.cats[index], input.value);
  };
  window.deleteCategoryAt = index => {
    if (S.cats[index]) deleteCategory(S.cats[index]);
  };
  window.cancelOrder = cancelLiveOrder;
  window.photo = uploadMenuPhoto;
  window.bulk = bulkUploadMenuPhotos;
  window.importInitialMenu = importInitialMenu;
  window.updateWalkInQueue = updateWalkInQueue;
  window.save = () => {
    if (currentProfile) localStorage.setItem(`scq_cart_${currentProfile.id}`, JSON.stringify(S.carts[currentProfile.id] || []));
  };
  window.notify = () => {};
  window.drawBell = async () => {
    if (!currentProfile) return;
    const unreadIds = S.notifs.filter(item => item.to === currentProfile.id && !item.read).map(item => item.id);
    if (unreadIds.length) {
      try {
        const { error } = await requireClient().from('notifications')
          .update({ is_read: true })
          .eq('user_id', currentProfile.id)
          .in('id', unreadIds);
        if (error) throw error;
        await refresh();
      } catch (error) {
        fail(error, 'Notification update');
        return;
      }
    }
    localDrawBell();
  };
  window.fav = async id => {
    const item = S.menu.find(menuItem => menuItem.id === id);
    if (!item?.backendId || !currentProfile) return toast('Favorite is unavailable');
    const favorite = S.favs[currentProfile.id] || [];
    try {
      const result = favorite.includes(id)
        ? await requireClient().from('favorites').delete().eq('user_id', currentProfile.id).eq('menu_item_id', item.backendId)
        : await requireClient().from('favorites').insert({ user_id: currentProfile.id, menu_item_id: item.backendId });
      if (result.error) throw result.error;
      await refresh();
      toast(favorite.includes(id) ? 'Removed from favorites' : 'Added to favorites');
    } catch (error) {
      fail(error, 'Favorite update');
    }
  };
  window.staff = () => {
    const view = localStaffView();
    const queue = S.queue || { walk_in_count: 0, active_preorders: 0, updated_at: null };
    return view.replace('<h2>Staff dashboard</h2>', `<h2>Staff dashboard</h2><div class="card"><h3>Physical walk-in queue</h3><div class="row"><label for="walk-in-count" style="margin:0">People waiting</label><input id="walk-in-count" type="number" min="0" max="10000" value="${queue.walk_in_count}" style="max-width:120px"><button class="btn s" onclick="updateWalkInQueue()">Update live count</button></div><small class="mu">Updated ${queue.updated_at ? new Date(queue.updated_at).toLocaleString() : 'not yet'}. Staff must maintain this count.</small></div>`);
  };
  window.showQueuePreview = () => {
    const heroNode = document.querySelector('#app .hero');
    if (!heroNode) return;
    const queue = S.queue;
    heroNode.insertAdjacentHTML('afterend', queue
      ? `<div class="card"><b>👥 Live walk-in queue</b><p style="font-size:24px;margin:4px 0;color:var(--pr)"><b>${queueLabel(queue.walk_in_count)}</b></p><p class="mu" style="margin:0">${queue.active_preorders} active pre-orders · Count updated ${queue.updated_at ? new Date(queue.updated_at).toLocaleTimeString() : 'recently'}</p></div>`
      : '<div class="card backend-notice">Live queue is unavailable. Please try again later.</div>');
  };
  window.checkout = () => {
    if (!cart().length) {
      go('/cart');
      return '';
    }
    return `<h2>Checkout</h2><div class="g2"><div class="card"><h3>Order summary</h3>${cart().map(entry => {
      const item = S.menu.find(menuItem => menuItem.id === entry.id);
      return item ? `<div class="row sp"><span>${esc(item.name)} × ${entry.qty}</span><span>${R(item.price * entry.qty)}</span></div>` : '';
    }).join('')}<hr style="border:0;border-top:1px solid var(--bd)"><div class="row sp"><b>Total (calculated securely by the server)</b><b>${R(sub())}</b></div></div><div class="card"><h3>Pickup</h3><p>Main Canteen, Pickup Counter</p><label>Note for the kitchen</label><input id="nt" maxlength="300" placeholder="Optional note"><h3>Payment</h3><p class="mu">Cash at counter. Online payment is not configured.</p><button class="btn" style="width:100%" onclick="pay()">Place cash order</button></div></div>`;
  };

  window.admin = () => {
    const view = localAdminView();
    const tabs = `<div class="tabs">${['Overview','Food Items','Categories','Orders','Team'].map(tab => `<button class="${ATAB===tab?'on':''}" onclick="ATAB='${tab}';render()">${tab}</button>`).join('')}</div>`;
    if (ATAB === 'Categories') return renderCategories();
    const team = `<h2>Admin panel</h2>${tabs}<div class="card"><h3>Invite staff</h3><p class="mu">The staff member receives an email invite and must set their own password.</p><div class="g2"><div><label>Name</label><input id="staff-name" maxlength="100" autocomplete="name"></div><div><label>Email</label><input id="staff-email" type="email" autocomplete="email"></div><div><label>Phone</label><input id="staff-phone" inputmode="numeric" maxlength="10" autocomplete="tel"></div></div><button class="btn" style="margin-top:12px" onclick="inviteStaff()">Send staff invitation</button></div><div class="card"><h3>Accounts and access</h3>${S.users.map(user => `<div class="card row sp"><div><b>${esc(user.name || user.display_name || 'User')}</b><div class="mu">${esc(user.phone || '')} · ${user.is_active ? 'Active' : 'Disabled'}</div></div><div class="row"><select aria-label="Role for ${esc(user.name || 'user')}" onchange="setRole('${user.id}',this.value)">${['student','staff','admin'].map(role => `<option value="${role}" ${user.role === role ? 'selected' : ''}>${role}</option>`).join('')}</select><button class="btn s ${user.is_active ? 'r' : 'g'}" onclick="setProfileActive('${user.id}',${!user.is_active})">${user.is_active ? 'Disable' : 'Enable'}</button></div></div>`).join('') || '<p class="mu">No accounts found.</p>'}</div>`;
    if (ATAB === 'Team') return team;
    let result = view.replace('<h2>Admin panel</h2>', `<h2>Admin panel</h2>${S.menu.length ? '' : '<div class="card backend-notice"><b>Menu is empty.</b> Import the starter menu once from this admin account.<br><button class="btn s" style="margin-top:8px" onclick="importInitialMenu()">Import starter menu</button></div>'}`);
    result = result.replace(/<div class="card row sp"><span>📷 Auto food photos[\s\S]*?<\/div><div class="card ov">/, '<div class="card ov">');
    result = result.replace(/<div class="tabs">[\s\S]*?<\/div>/, tabs);
    if (ATAB === 'Orders') {
      const orders = [...S.orders].reverse();
      const table = orders.length ? `<div class="card ov"><table><tr><th>Order</th><th>Token</th><th>Student</th><th>Items</th><th>Total</th><th>Payment</th><th>Status</th><th></th></tr>${orders.map(order => `<tr><td>${order.id}<br><small class="mu">${esc(order.time)}</small></td><td>${esc(order.token)}</td><td>${esc(order.studentName || '-')}</td><td>${order.items.map(item => `${esc(item.name)} ×${item.qty}`).join(', ')}</td><td>${R(order.total)}</td><td>${esc(order.payStatus)}</td><td>${tag(order.status)}</td><td>${['Placed','Accepted','Preparing','Ready'].includes(order.status) ? `<button class="btn r s" onclick="cancelOrder('${order.id}')">Cancel</button>` : ''}</td></tr>`).join('')}</table></div>` : '<div class="card mu">No orders yet.</div>';
      result = result.replace(/<div class="card">[\s\S]*?<\/div>$/, table);
    }
    return result.replace('<h2>Admin panel</h2>', `<h2>Admin panel</h2><div class="card"><h3>Physical walk-in queue</h3><div class="row"><input id="walk-in-count" type="number" min="0" max="10000" value="${S.queue?.walk_in_count || 0}" style="max-width:120px"><button class="btn s" onclick="updateWalkInQueue()">Update live count</button><span class="mu">${S.queue?.active_preorders || 0} active pre-orders</span></div></div>`);
  };

  async function initialize() {
    if (!config || !/^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(config.url || '') ||
        !/^sb_publishable_[A-Za-z0-9_-]+$/.test(config.publishableKey || '') ||
        !sdk?.createClient) {
      app.innerHTML = '<div class="card backend-notice"><b>Backend configuration is missing.</b> Set the Supabase project URL and publishable key in supabase/config.js.</div>';
      return;
    }
    client = sdk.createClient(config.url, config.publishableKey, {
      auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true }
    });
    try {
      const health = await fetch(`${config.url}/auth/v1/health`, {
        headers: { apikey: config.publishableKey }
      });
      if (!health.ok) {
        const response = await health.json().catch(() => ({}));
        throw new Error(response.message || `Supabase health check returned HTTP ${health.status}`);
      }
      const { data, error } = await client.auth.getSession();
      if (error) throw error;
      if (data.session) {
        await loadRemoteState();
        setSess(currentProfile.id);
        listen();
      } else {
        S = seed();
        S.users = [];
        S.menu = [];
        S.cats = [];
        setSess(null);
      }
      isReady = true;
      render();
      if (!data.session) document.querySelector('#app').insertAdjacentHTML('afterbegin', '<div class="backend-notice"><b>Real Supabase sign-in enabled.</b> Create a student account or sign in. Staff and admin access is granted by an administrator.</div>');
    } catch (error) {
      console.error('Supabase startup failed:', error);
      app.innerHTML = `<div class="card backend-notice"><b>Could not connect to Supabase.</b><p>${esc(error.message || 'Unknown connection error')}</p><p>Check that the project URL and publishable key belong to the same project, the database setup is complete, and the network is available.</p></div>`;
    }
  }

  window.addEventListener('hashchange', () => {
    if (!isReady) return;
    if (!currentProfile && !['login','register','staff-preview','admin-preview'].includes(location.hash.slice(2).split('/')[0])) go('/login');
  });
  initialize();
})();
