// Every page except /login needs a signed-in identity.
export default defineNuxtRouteMiddleware(async (to) => {
  if (to.path === '/login') return;
  const { load, me } = useIdentity();
  await load();
  if (!me.value) return navigateTo(`/login?returnTo=${encodeURIComponent(to.fullPath)}`);
  const { tenant, setTenant } = useTenant();
  const allowed = me.value.tenants.includes('*') ? null : me.value.tenants;
  if (allowed && allowed.length && !allowed.includes(tenant.value)) setTenant(allowed[0]!);
});
