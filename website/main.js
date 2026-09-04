document.querySelectorAll('a[href^="#"]').forEach((link) => {
  link.addEventListener('click', (event) => {
    const target = document.querySelector(link.getAttribute('href'));
    if (target) { event.preventDefault(); target.scrollIntoView({ behavior: 'smooth' }); }
  });
});

const maleNames = ['陈磊', '赵阳', '刘洋', '周凯', '孙浩', '高远', '何伟'];
const crewName = document.querySelector('#random-crew-name');
if (crewName) {
  crewName.textContent = maleNames[Math.floor(Math.random() * maleNames.length)];
}
