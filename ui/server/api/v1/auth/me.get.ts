// GET /api/v1/auth/me → the signed-in identity (never the tokens)
import { activeSession } from '../../../utils/session';

export default defineEventHandler(async (event) => {
  const session = await activeSession(event);
  if (!session) throw createError({ statusCode: 401, statusMessage: 'unauthorized' });
  return {
    data: {
      ...session.user,
      accessExpiresAt: new Date(session.expiresAt).toISOString(),
    },
  };
});
