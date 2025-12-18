const admin = require('firebase-admin');

if (!admin.apps.length) {
  admin.initializeApp({
    projectId: 'talia-chat-app-v2',
  });
}

const db = admin.firestore();

async function fixParentChildLink() {
  const facuId = 'bFtKsnGbRPZUisb6xyHVVxxaRBh2';
  const tadeoId = 'yOV2icEkwpevXsiPExZYcwOqLg33';

  console.log('=== CREANDO VÍNCULO PADRE-HIJO ===\n');

  const batch = db.batch();

  // 1. Crear documento en parent_child_links
  const linkId = `${facuId}_${tadeoId}`;
  const linkRef = db.collection('parent_child_links').doc(linkId);

  console.log('1. Creando parent_child_links/' + linkId);
  batch.set(linkRef, {
    parentId: facuId,
    childId: tadeoId,
    status: 'active',
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    linkedAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  // 2. Actualizar documento del padre con linkedChildrenIds
  const parentRef = db.collection('users').doc(facuId);
  console.log('2. Actualizando users/' + facuId + ' con linkedChildrenIds');
  batch.update(parentRef, {
    linkedChildrenIds: admin.firestore.FieldValue.arrayUnion(tadeoId),
  });

  // 3. Actualizar documento del hijo con linkedParentId
  const childRef = db.collection('users').doc(tadeoId);
  console.log('3. Actualizando users/' + tadeoId + ' con linkedParentId');
  batch.update(childRef, {
    linkedParentId: facuId,
  });

  // 4. Ejecutar batch
  console.log('\n4. Ejecutando batch...');
  await batch.commit();

  console.log('\n✅ Vínculo creado exitosamente!');

  // Verificar
  console.log('\n=== VERIFICACIÓN ===\n');

  const verifyLink = await linkRef.get();
  console.log('Link document exists:', verifyLink.exists);

  const verifyParent = await parentRef.get();
  console.log('Parent linkedChildrenIds:', verifyParent.data()?.linkedChildrenIds);

  const verifyChild = await childRef.get();
  console.log('Child linkedParentId:', verifyChild.data()?.linkedParentId);
}

fixParentChildLink()
  .then(() => process.exit(0))
  .catch(e => {
    console.error('Error:', e);
    process.exit(1);
  });
