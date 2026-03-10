// Get DOM elements
const form = document.getElementById('contactForm');
const submitBtn = document.getElementById('submitBtn');
const successMsg = document.getElementById('successMessage');
const errorMsg = document.getElementById('errorMessage');

// form submit handler
form.addEventListener('submit', async function(event) {

    // step 1: Prevent default form submission
    event.preventDefault();

    // step 2: get form values
    const name = document.getElementById('name').value;
    const email = document.getElementById('email').value;
    const message = document.getElementById('message').value;

    // step 3: show loading state
    submitBtn.disabled = true;
    submitBtn.textContent = 'Sending...';
    successMsg.style.display = 'none';
    errorMsg.style.display = 'none';

    // step 4: send to API using fetch()
try {
    const response = await fetch(CONFIG.API_ENDPOINT, {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
            'x-api-key': CONFIG.API_KEY
        },
        body: JSON.stringify({name, email, message})
    });

    // step 5: Handle success response
    if (response.ok) {
        const data = await response.json();

        // show success message
        successMsg.style.display = 'block';
        errorMsg.style.display = 'none';

        // clear form
        form.reset();

        // Log submission ID
        console.log('submission ID:', data.submissionId);

    } else {
        // API returned error status (400, 500 etc)
        throw new Error('Server returned ${response.status}');
    }

   } catch (error) {
        // Step 6: Handle errors
        console.error('Error:', error);
        errorMsg.style.display = 'block';
        
    } finally {
        // Re-enable button
        submitBtn.disabled = false;
        submitBtn.textContent = 'Send Inquiry';
    }
});

