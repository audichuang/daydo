import { defineHandler } from 'void';
import { createDb } from 'void/db';
import { requireUser } from '../../src/auth/middleware';
import { sanitizeGoogleAvatarUrl } from '../../src/auth/providers';
import { updateUserAvatar } from '../../src/auth/session';
import { readJsonObject } from '../../src/http';

export const PUT = defineHandler(async (c) => {
  const userId = await requireUser(c);
  if (userId instanceof Response) return userId;

  const body = await readJsonObject(c);
  if (!body) {
    return c.json({ error: 'Invalid JSON body' }, 400);
  }

  const avatarUrl = sanitizeGoogleAvatarUrl(body.avatarUrl);
  if (!avatarUrl) {
    return c.json(
      { error: 'avatarUrl must be an https googleusercontent.com URL within 2048 characters' },
      400,
    );
  }

  const db = createDb(c.env.DB, { session: 'first-primary' });
  const result = await updateUserAvatar(db, { userId, avatarUrl });
  if (!result) {
    return c.json({ error: 'User not found' }, 404);
  }
  return c.json(result, 200);
});
