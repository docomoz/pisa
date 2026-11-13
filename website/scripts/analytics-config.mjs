// The measurement ID is public, but kept separate so routine builds retain it.
export function measurementIdFromConfig(config, env = process.env) {
  const id = Object.hasOwn(env, 'PISA_GA_MEASUREMENT_ID')
    ? env.PISA_GA_MEASUREMENT_ID
    : Object.hasOwn(env, 'PISYA_GA_MEASUREMENT_ID')
      ? env.PISYA_GA_MEASUREMENT_ID
      : config.gaMeasurementId;
  if (typeof id !== 'string' || (id && !/^G-[A-Z0-9]+$/.test(id))) {
    throw new Error('GA4 measurement ID must be empty or have the form G-XXXXXXXXXX');
  }
  return id;
}
